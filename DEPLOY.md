# IBKR extension — deploy & branch scheme

## What runs (single source of truth)
MoneyMoney loads the extension from its sandbox, NOT from this clone:

    ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/ibkr.lua

That installed file is authoritative for what actually runs. This clone is for
version control only; editing here changes nothing until you deploy (copy in).

## Branch roles — never mix these
| Branch | Meaning | Rule |
|--------|---------|------|
| `main` | mirror of upstream `krambox/moneymoney-ibkr` | never commit personal changes here |
| `local-live` | **exactly what is installed** (personal USD build) | the build of record; backed up on the `karero` fork |
| `fix/*` | PR branches off upstream `main` | what you submit; EUR-preserving, no personalizations |

Personal build = USD currency + futures (FUT) contracts/PnL-to-NAV + short PnL%
sign fix + fail-fast (no retry). The USD parts must NEVER go into a `fix/*` PR.

## Deploy (clone -> live)
    EXT="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions"
    git checkout local-live
    cp "$EXT/ibkr.lua" "$EXT/ibkr.lua.bak.$(date +%Y%m%d-%H%M%S)"   # back up current first
    cp ibkr.lua "$EXT/ibkr.lua"                                     # deploy
    # then refresh the IBKR account in MoneyMoney to test

## Rollback (if a deploy misbehaves)
    cp "$EXT/"ibkr.lua.bak.<newest-timestamp> "$EXT/ibkr.lua"

## Backup / off-machine copy
`git push fork local-live:refs/heads/local-live`  (fork = git@github.com:karero/moneymoney-ibkr.git)

## Gotcha
Some clones have `push.default = upstream`, which silently retargets a plain
`git push origin <branch>` onto the fork's default branch. Always push with an
explicit refspec: `git push <remote> <branch>:refs/heads/<branch>`.

## Note: GetStatement hostname (2026-06-13, f91c869)
GetStatement must always use FLEX_BASE_URL (ndcdyn) — do NOT follow the
gdcdyn `<Url>` from the SendRequest response. Both are CNAMEs to the same
Akamai edge, but a stale client DNS cache made gdcdyn unresolvable while
ndcdyn worked ("Could not resolve DNS name gdcdyn..."). Upstream `main`
already does this; following `<Url>` was a local-live divergence (so there
is nothing to upstream). Regression test pins it in test/ibkr_test.lua.
