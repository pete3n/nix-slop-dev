# Accounts require an explicit projectName (ADR-0014 deny-by-default). The
# zero-touch / apps path (no projectName → the __SLOP_ENV_PROJECT_NAME__
# placeholder) keeps today's single-credential behavior and cannot apply
# per-Account substitution. Declaring `accounts` there would bake an
# __SLOP_ENV_ACCOUNT__ placeholder that the placeholder launcher never resolves,
# yielding a silently broken launcher. So the combination is refused at EVAL.
#
# Eval-level check: mkBins with `accounts` but no `projectName` must fail
# evaluation; the same registry WITH a concrete projectName must evaluate.
{
  self,
  pkgs,
}:
let
  slop = self.lib.slopEnv pkgs;
  accts = {
    acme = {
      type = "oauth";
    };
  };

  zerotouch = builtins.tryEval (
    (slop.mkBins {
      accounts = accts;
      defaultAccount = "acme";
    }).shellHook
  );
  concrete = builtins.tryEval (
    (slop.mkBins {
      projectName = "acct-zt";
      accounts = accts;
      defaultAccount = "acme";
    }).shellHook
  );
in
if zerotouch.success then
  throw "zero-touch+Accounts not refused: mkBins with `accounts` and no projectName must fail at eval"
else if !concrete.success then
  throw "regression: Accounts with a concrete projectName must still evaluate"
else
  pkgs.runCommand "account-zerotouch-refused" { } ''
    echo "ok: Accounts on the zero-touch path refused; concrete projectName accepted" > $out
  ''
