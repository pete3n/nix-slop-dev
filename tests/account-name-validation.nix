# Account-name validation (ADR-0014 deny-by-default). Account names ride into
# the launcher's registry-membership loop, the apikey case pattern, the sed
# replacement, and the per-Account paths. A name carrying shell metacharacters,
# a sed delimiter, whitespace, or a path separator would corrupt the launcher,
# so the registry is constrained to a safe charset at EVAL time — a malformed
# registry is refused at build, not misbehaving at launch.
#
# This is an eval-level check: it asserts that constructing a Slop Env with an
# unsafe Account name FAILS evaluation, and that a safe name still evaluates.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;

  mkWithAccountName =
    name:
    (slop.mkBins {
      projectName = "acct-nameval";
      accounts = {
        ${name} = {
          type = "oauth";
        };
      };
      defaultAccount = name;
    }).shellHook;

  # An unsafe name (pipe is both a shell metacharacter and the sed delimiter)
  # must be rejected; a normal name must still evaluate.
  unsafe = builtins.tryEval (mkWithAccountName "bad|name");
  safe = builtins.tryEval (mkWithAccountName "good-acct.1");
in
if unsafe.success then
  throw "account-name validation regressed: an Account name with shell/sed metacharacters was accepted"
else if !safe.success then
  throw "account-name validation too strict: a safe Account name (good-acct.1) was rejected"
else
  pkgs.runCommand "account-name-validation" { } ''
    echo "ok: unsafe Account name refused at eval, safe name accepted" > $out
  ''
