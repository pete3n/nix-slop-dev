# Functional test for the exported templates (ADR-0006).
#
# Proves that each exported template's composed Slop Env yields an enforcing
# Jail carrying the template's configured tooling — the "develop -> enforce"
# half of the template user journey.
#
# Scope note: a nixosTest is hermetic (no network), so the literal
# `nix flake init -t` + `nix develop` (which fetch the template's flake inputs)
# cannot run inside the guest. Instead each template's jail is reconstructed
# from the template's REAL config paths via the same lib the template calls
# (slop.mkShell -> mkBins). This is faithful by construction: the byte-equality
# checks (tests/template-claude-code-drv.nix, tests/template-nvim-dev-drv.nix)
# pin that the lib reproduces each template's devShell from exactly these args,
# and template-default-config-matches-lib.nix pins the config. Those guard
# composition; this guards behaviour.
#
# Asserts, inside each template's jail:
#   #4 path-hidden        — $HOME/.ssh is confined out
#   #5 project-rw         — the bound cwd (mount-cwd) is writable
#   #6 host-binary-absent — sudo is off the jail PATH
# and, for the nvim template additionally, that its lua tooling + headless test
# plumbing (lua-language-server / stylua / busted) reach the jail PATH.
{
  pkgs,
  self,
}:
let
  slop-oracle = pkgs.writeShellScriptBin "slop-oracle" (builtins.readFile ./oracle/slop-oracle.sh);
  mkBins = (self.lib.slopEnv pkgs).mkBins;

  # claude-code template: exact config args from templates/claude-code/flake.nix
  # (projectPkgs is empty there, so the jail is unmodified — the oracle rides in
  # via the bound cwd, not projectPkgs, keeping the composition faithful).
  claudeTemplate =
    (mkBins {
      projectName = "tmpl-claude";
      agentMdFile = ../templates/claude-code/slop-env/claude-config/CLAUDE.md;
      rulesDir = ../templates/claude-code/slop-env/claude-config/rules;
      skillsDir = ../templates/claude-code/slop-env/claude-config/skills;
    }).jailedShell;

  # nvim-dev template: config args from templates/claude-code-nvim-dev/flake.nix
  # plus the STOCK-nixpkgs subset of its projectPkgs sufficient for the tooling
  # claim. nvimDev is omitted deliberately — it needs the template's neovim
  # overlay and is irrelevant to "tooling reaches the jail PATH"; full-fidelity
  # composition (overlay, extraCombinators, projectEnv) is covered by the nvim
  # byte-eq check.
  nvimTemplate =
    (mkBins {
      projectName = "tmpl-nvim";
      agentMdFile = ../templates/claude-code-nvim-dev/slop-env/claude-config/CLAUDE.md;
      rulesDir = ../templates/claude-code-nvim-dev/slop-env/claude-config/rules;
      skillsDir = ../templates/claude-code-nvim-dev/slop-env/claude-config/skills;
      projectPkgs = with pkgs; [
        lua-language-server
        stylua
        luajitPackages.busted
      ];
    }).jailedShell;

  # pi-agent template: config args from templates/pi-agent/flake.nix, selecting
  # the pi Agent Profile (ADR-0009). projectPkgs is omitted here — hunk/worktrunk
  # presence rides in via the byte-eq drv check; this arm asserts the universal
  # jail invariants for pi's combinator list (global ~/.pi/agent + per-project
  # sessions, all via try- binds so no pre-seeded sources are required).
  piTemplate =
    (mkBins {
      projectName = "tmpl-pi";
      agent = (self.lib.slopEnv pkgs).profiles.pi;
      agentMdFile = ../templates/pi-agent/slop-env/pi-config/AGENTS.md;
      rulesDir = ../templates/pi-agent/slop-env/pi-config/rules;
      skillsDir = ../templates/pi-agent/slop-env/pi-config/skills;
    }).jailedShell;

  # opencode template: config args from templates/opencode/flake.nix, selecting
  # the opencode Agent Profile (ADR-0010). projectPkgs is omitted here —
  # hunk/worktrunk presence rides in via the byte-eq drv check; this arm asserts
  # the universal jail invariants for opencode's combinator list (global state
  # binds + parent-bound Scratch/Exchange, all via try- binds so no pre-seeded
  # sources are required).
  opencodeTemplate =
    (mkBins {
      projectName = "tmpl-opencode";
      agent = (self.lib.slopEnv pkgs).profiles.opencode;
      agentMdFile = ../templates/opencode/slop-env/opencode-config/AGENTS.md;
      rulesDir = ../templates/opencode/slop-env/opencode-config/rules;
      skillsDir = ../templates/opencode/slop-env/opencode-config/skills;
    }).jailedShell;
in
pkgs.testers.runNixOSTest {
  name = "slop-template-functional";

  nodes.agent =
    { ... }:
    {
      users.users.agent = {
        isNormalUser = true;
      };
    };

  testScript = ''
    agent.wait_for_unit("multi-user.target")

    # Host secret outside any jail's curated view, and the shared credentials
    # file the Linux jail's rw-bind combinator requires (non-optional source).
    agent.succeed(
        "su - agent -c 'mkdir -p ~/.ssh ~/.local/state/claude/shared"
        " && echo TOPSECRET > ~/.ssh/id_secret && chmod 600 ~/.ssh/id_secret"
        " && touch ~/.local/state/claude/shared/.credentials.json'",
    )

    def template_jail(shell_bin, proj, extra_check=""):
        # Stage the oracle in the project dir; mount-cwd binds it into the jail
        # so ./slop-oracle resolves inside (the template's projectPkgs are not
        # modified). Done as the agent so the dir/files are agent-owned.
        agent.succeed(
            f"su - agent -c 'mkdir -p {proj}"
            f" && cp ${slop-oracle}/bin/slop-oracle {proj}/slop-oracle"
            f" && chmod +x {proj}/slop-oracle'"
        )
        cmd = (
            f"./slop-oracle path-rw {proj}"
            " && ./slop-oracle path-hidden /home/agent/.ssh/id_secret"
            " && ./slop-oracle no-host-bin sudo"
        )
        if extra_check:
            cmd += f" && {extra_check}"
        agent.succeed(f"su - agent -c 'cd {proj} && {shell_bin} -c \"{cmd}\"' ")

    # claude-code template jail: the universal jail invariants.
    template_jail("${claudeTemplate}/bin/jailed-shell", "/home/agent/proj-claude")

    # pi-agent template jail: same universal invariants for the pi profile.
    template_jail("${piTemplate}/bin/jailed-shell", "/home/agent/proj-pi")

    # opencode template jail: same universal invariants for the opencode profile.
    template_jail("${opencodeTemplate}/bin/jailed-shell", "/home/agent/proj-opencode")

    # nvim-dev template jail: same invariants, plus its lua tooling + headless
    # test plumbing must be present on the jail PATH.
    template_jail(
        "${nvimTemplate}/bin/jailed-shell",
        "/home/agent/proj-nvim",
        extra_check="command -v lua-language-server && command -v stylua && command -v busted",
    )

    # Negative control: the secret really exists outside the jails, so the
    # path-hidden PASSes mean "confined out", not "never created".
    agent.succeed("grep -q TOPSECRET /home/agent/.ssh/id_secret")
  '';
}
