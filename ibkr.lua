-- LOCAL BUILD — personalized, NOT the upstream extension. Do not submit as-is.
-- Differences vs krambox/moneymoney-ibkr: base currency USD (not EUR); futures (FUT)
-- report contracts + contribute 0 to NAV (P&L already settled to cash); short-position PnL% sign fix;
-- one cash account PER CURRENCY (USD/EUR/CAD/...) from the Flex Cash Report.
-- Adopted from upstream v0.5: AccountManagement/FlexWebService endpoint, URL-encoded params,
-- safer block parsing, Flex-statement validation. Fail-fast on Flex errors (no retry, by choice).
-- Requires the Flex Query to include the Cash Report section with Currency Breakout.
-- Source of truth / backup: karero/moneymoney-ibkr branch `local-live`.

WebBanking {
  version = 0.44,
  country = "de",
  description = "Include your IBKR stock portfolio in MoneyMoney (local USD build).",
  services = {"IBKR"}
}

local FLEX_BASE_URL = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"
local FLEX_VERSION = "3"
local FLEX_USER_AGENT = "Java/1.8"

local parseargs = function(s)
  local arg = {}
  string.gsub(s, "([%-%w]+)=([\"'])(.-)%2", function(w, _, value)
      value = string.gsub(value, "&quot;", "\"");
      value = string.gsub(value, "&apos;", "'");
      value = string.gsub(value, "&gt;", ">");
      value = string.gsub(value, "&lt;", "<");
      value = string.gsub(value, "&amp;", "&");
      arg[w] = value
  end)
  return arg
end

local parseBlock = function(content, k)
  if content == nil then return nil end
  return string.match(content, "<" .. k .. "[^>]*>(.-)</" .. k .. ">")
end

local function isFlexStatement(content)
  if content == nil or content == "" then return false end
  return string.find(content, "<FlexQueryResponse", 1, true) ~= nil or
      string.find(content, "<FlexStatement ", 1, true) ~= nil or
      string.find(content, "<FlexStatements", 1, true) ~= nil
end

local function encodeParam(value)
  return MM.urlencode(tostring(value), "UTF-8")
end

local function newConnection()
  local c = Connection()
  c.useragent = FLEX_USER_AGENT
  return c
end

local connection = newConnection()
local token
local query
local code
local statementContent

-- Fetch + cache + validate the Flex statement (fail-fast, no retry).
local function loadStatement()
  if statementContent == nil then
      -- Deliberately ignore the <Url> host from the SendRequest response
      -- (gdcdyn.interactivebrokers.com): it is an alias for the same Akamai
      -- edge as FLEX_BASE_URL, and the extra hostname can fail on stale
      -- client DNS caches while ndcdyn was just resolved by SendRequest.
      local content = connection:get(
          FLEX_BASE_URL .. "/GetStatement?t=" .. encodeParam(token) .. "&q=" .. encodeParam(code) .. "&v=" .. FLEX_VERSION)
      local ec = parseBlock(content, 'ErrorCode')
      if ec ~= nil then
          local em = parseBlock(content, 'ErrorMessage') or ""
          return nil, "IBKR Flex GetStatement error " .. ec .. ": " .. em
      end
      if not isFlexStatement(content) then
          return nil, "IBKR Flex GetStatement failed: response did not contain a Flex statement."
      end
      statementContent = content
  end
  return statementContent
end

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "IBKR"
end

function InitializeSession(protocol, bankCode, username, customer, password)
  token = password
  query = username
  connection = newConnection()

  local content = connection:get(
      FLEX_BASE_URL .. "/SendRequest?t=" .. encodeParam(token) ..
          "&q=" .. encodeParam(query) .. "&v=" .. FLEX_VERSION)
  local status = parseBlock(content, "Status")
  if status == "Success" then
      code = parseBlock(content, "ReferenceCode")
      print("8:" .. tostring(code))
      return
  end
  local ec = parseBlock(content, 'ErrorCode')
  local em = parseBlock(content, 'ErrorMessage')
  if ec and em then
      return "IBKR Flex SendRequest error " .. ec .. ": " .. em
  end
  return content
end

function ListAccounts(knownAccounts)
  local accounts = {{
      name = "IBKR",
      accountNumber = "1",
      currency = "USD",
      portfolio = true,
      type = "AccountTypePortfolio"
  }}

  -- One cash account per currency held (USD/EUR/CAD/...), discovered from the
  -- Flex Cash Report. USD keeps accountNumber "2" to preserve the existing
  -- account's history; other currencies use the currency code as accountNumber.
  local content, err = loadStatement()
  if err ~= nil then
      print("IBKR ListAccounts: " .. err .. " — falling back to a single USD cash account.")
  end
  local cashReport = content and parseBlock(content, 'CashReport')
  local found = false
  if cashReport then
      for row in cashReport:gmatch("<CashReportCurrency(.-)/>") do
          local c = parseargs(row)
          if c.levelOfDetail == "Currency" and c.currency and c.currency ~= "BASE_SUMMARY" then
              accounts[#accounts + 1] = {
                  name = "IBKR Cash " .. c.currency,
                  accountNumber = (c.currency == "USD") and "2" or c.currency,
                  currency = c.currency,
                  type = "AccountTypeOther"
              }
              found = true
          end
      end
  end
  if not found then
      -- Fallback: single base-currency cash account (e.g. Cash Report not enabled).
      accounts[#accounts + 1] = {
          name = "IBKR Cash",
          accountNumber = "2",
          currency = "USD",
          type = "AccountTypeOther"
      }
  end

  return accounts
end

function stringToTimestamp(str)
  local datePattern = '(%d%d%d%d)(%d%d)(%d%d)'
  local year, month, day  = str:match(datePattern)
  if year and month and day then
      local timestamp = os.time{day=day,month=month,year=year}
      return timestamp
  end
end

function RefreshAccount(account, since)
  print("RefreshAccount " .. JSON():set(account):json())

  local statementContent, err = loadStatement()
  if err ~= nil then
      return err
  end

  if tostring(account.accountNumber) == "1" then
      local positions = parseBlock(statementContent, 'OpenPositions')
      local securities = {}
      for p in positions:gmatch("<OpenPosition(.-)/>") do
          print(p)
          local pos = parseargs(p)
          securities[#securities + 1] = {
              name = pos.description,
              isin = pos.isin,
              securityNumber = pos.isin,
              market = pos.listingExchange,
              -- Futures: report number of contracts. Stocks/options keep share-equivalent (position × multiplier).
              quantity = pos.assetCategory == "FUT" and pos.position or pos.position * pos.multiplier,
              originalCurrencyAmount = pos.positionValue,
              currencyOfOriginalAmount = pos.currency,
              price = pos.markPrice,
              currencyOfPrice = pos.currency,
              purchasePrice = pos.costBasisPrice,
              currencyOfPurchasePrice = pos.currency,
              exchangeRate = 1 / pos.fxRateToBase,
              -- Futures contribute 0 to NAV: daily MTM already settles their P&L into the cash
              -- balance, so counting notional positionValue OR fifoPnlUnrealized here would
              -- double-count. Confirmed against IB Net Liq (160,270 ~ non-fut MV + cash).
              amount = (pos.assetCategory == "FUT" and 0 or pos.positionValue) * pos.fxRateToBase,
              -- PnL %: fifoPnlUnrealized / |costBasisMoney| gives correct sign for both longs and shorts.
              userdata = {{key="_profit",value=string.format("%.02f", pos.fifoPnlUnrealized*pos.fxRateToBase) .. " USD / " .. string.format("%.05f", 100 * pos.fifoPnlUnrealized / math.abs(pos.costBasisMoney)) .. " %"}}
              --userdata = {{key="_profit",value=string.format("%.02f", pos.fifoPnlUnrealized) .. " USD / " .. string.format("%.05f", 100/pos.costBasisMoney*pos.positionValue-100) .. " %"}}

          }

      end
      -- Return balance and array of transactions.
      return {
          securities = securities
      }
  else
      -- Per-currency cash account: balance + transactions for THIS account's currency.
      local acctCurrency = account.currency
      local balance = 0
      local cashReport = parseBlock(statementContent, 'CashReport')
      if cashReport then
          for row in cashReport:gmatch("<CashReportCurrency(.-)/>") do
              local c = parseargs(row)
              if c.levelOfDetail == "Currency" and c.currency == acctCurrency then
                  balance = tonumber(c.endingCash) or 0
              end
          end
      end

      local funds = parseBlock(statementContent, 'StmtFunds')
      local transactions = {}
      if funds then
          for p in funds:gmatch("<StatementOfFundsLine(.-)/>") do
              local sm = parseargs(p)
              if sm.activityCode ~= 'ADJ' and sm.currency == acctCurrency then
                  transactions[#transactions + 1] = {
                      name = sm.description,
                      amount = tonumber(sm.amount) or 0,
                      currency = acctCurrency,
                      bookingDate = stringToTimestamp(sm.reportDate),
                      valueDate = stringToTimestamp(sm.settleDate),
                      transactionCode = sm.transactionID,
                      purpose = sm.activityDescription,
                      bookingText = sm.activityCode
                  }
              end
          end
      end
      return {
          balance = balance,
          transactions = transactions
      }
  end
end

function EndSession()
  -- Logout.
end

