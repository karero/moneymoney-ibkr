-- Regression test for the local-live ibkr.lua build.
-- Stubs the MoneyMoney runtime and feeds captured Flex responses (fixtures/),
-- so it runs offline with no IBKR calls and no token. Run from anywhere:
--     lua test/ibkr_test.lua
-- Exits non-zero on any failed assertion.

local here = arg[0]:match("(.*/)") or "./"

local function slurp(p)
  local f = assert(io.open(p, "r"), "cannot open " .. p)
  local s = f:read("*a"); f:close(); return s
end

local sendXml = slurp(here .. "fixtures/send.xml")
local stmtXml = slurp(here .. "fixtures/statement.xml")

-- MoneyMoney runtime stubs
function WebBanking(t) end
function Connection()
  return { get = function(self, url)
    if string.find(url, "SendRequest", 1, true) then return sendXml end
    return stmtXml
  end }
end
MM = { urlencode = function(s) return s end }
function JSON() local o = {}; o.set = function(self) return self end; o.json = function() return "{}" end; return o end
ProtocolWebBanking = "WB"

-- Silence the extension's debug prints during the test.
local realprint = print
print = function() end

dofile(here .. "../ibkr.lua")

-- ---- assertions -------------------------------------------------------------
local failures = 0
local function check(label, cond)
  if cond then
    realprint("  ok   " .. label)
  else
    failures = failures + 1
    realprint("  FAIL " .. label)
  end
end
local function approx(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

InitializeSession(nil, nil, "1509723", nil, "TESTTOKEN")

-- ListAccounts: portfolio + one cash account per currency.
local accts = ListAccounts({})
local byCur = {}
local portfolio
for _, a in ipairs(accts) do
  if a.portfolio then portfolio = a else byCur[a.currency] = a end
end
check("4 accounts returned", #accts == 4)
check("portfolio account present (num 1, USD)", portfolio and tostring(portfolio.accountNumber) == "1" and portfolio.currency == "USD")
check("USD cash account keeps accountNumber 2", byCur.USD and tostring(byCur.USD.accountNumber) == "2")
check("EUR cash account present (num EUR)", byCur.EUR and tostring(byCur.EUR.accountNumber) == "EUR")
check("CAD cash account present (num CAD)", byCur.CAD and tostring(byCur.CAD.accountNumber) == "CAD")

-- RefreshAccount: per-currency balances (native endingCash) + transaction routing.
local function refresh(a) return RefreshAccount({ accountNumber = a.accountNumber, currency = a.currency }, 0) end

local usd = refresh(byCur.USD)
check("USD balance == endingCash 9414.505320102", approx(usd.balance, 9414.505320102))
check("USD has 4 (non-ADJ) transactions", #usd.transactions == 4)

local eur = refresh(byCur.EUR)
check("EUR balance == 4406.02", approx(eur.balance, 4406.02))
check("EUR has 0 transactions (no EUR activity)", #eur.transactions == 0)

local cad = refresh(byCur.CAD)
check("CAD balance == -9.57004649", approx(cad.balance, -9.57004649))
check("CAD has 0 transactions", #cad.transactions == 0)

-- Securities: futures reported as contracts + PnL-to-NAV (not notional).
local sec = refresh(portfolio)
check("portfolio returns 3 securities", sec.securities and #sec.securities == 3)
local mes
for _, s in ipairs(sec.securities or {}) do
  if s.name == "MES 18JUN26" then mes = s end
end
check("MES futures quantity is contracts (-3), not -15", mes and tostring(mes.quantity) == "-3")
check("MES futures amount is 0 (P&L lives in cash, not double-counted)", mes and approx(tonumber(mes.amount), 0))

-- ---- report -----------------------------------------------------------------
realprint("")
if failures == 0 then
  realprint("ALL TESTS PASSED")
  os.exit(0)
else
  realprint(failures .. " TEST(S) FAILED")
  os.exit(1)
end
