WebBanking {
  version = 0.4,
  country = "de",
  description = "Include your IBKR stock portfolio in MoneyMoney.",
  services = {"IBKR"}
}

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
  return string.match(content, "^.+<" .. k .. ">(.+)</" .. k .. ">.+$")
end

local connection = Connection()
local token
local query
local code
local statementUrl

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "IBKR"
end

function InitializeSession(protocol, bankCode, username, customer, password)
  token = password
  query = username
  connection = Connection()

  local content = connection:get(
      "https://ndcdyn.interactivebrokers.com/Universal/servlet/FlexStatementService.SendRequest?t=" .. token ..
          "&q=" .. query .. "&v=3")
  local status = string.match(content, "^.+<Status>(.+)</Status>.+$")
  if status == "Success" then
      code = string.match(content, "^.+<ReferenceCode>(.+)</ReferenceCode>.+$")
      statementUrl = string.match(content, "<Url>%s*(.-)%s*</Url>")
      print("8:" .. code)
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
  local account = {
      name = "IBKR",
      accountNumber = 1,
      currency = "USD",
      portfolio = true,
      type = "AccountTypePortfolio"
  }
  local account2 = {
      name = "IBKR Cash",
      accountNumber = 2,
      currency = "USD",
      type = "AccountTypeOther"
  }

  return {account, account2}
end

local statementContent

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

  if statementContent == nil then
      local getUrl = statementUrl or
          "https://gdcdyn.interactivebrokers.com/Universal/servlet/FlexStatementService.GetStatement"
      statementContent, charset, mimeType = connection:get(
          getUrl .. "?t=" .. token .. "&q=" .. code .. "&v=3")
      local ec = parseBlock(statementContent, 'ErrorCode')
      if ec ~= nil then
          local em = parseBlock(statementContent, 'ErrorMessage') or ""
          return "IBKR Flex GetStatement error " .. ec .. ": " .. em
      end
  end
  if account.accountNumber == "1" then
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
              -- Futures contribute only their unrealized PnL to NAV (daily MTM settles to cash),
              -- not their notional positionValue. Without this, futures distort the balance hugely.
              amount = (pos.assetCategory == "FUT" and pos.fifoPnlUnrealized or pos.positionValue) * pos.fxRateToBase,
              -- PnL %: fifoPnlUnrealized / |costBasisMoney| gives correct sign for both longs and shorts.
              userdata = {{key="_profit",value=string.format("%.02f", pos.fifoPnlUnrealized*pos.fxRateToBase) .. " USD / " .. string.format("%.05f", 100 * pos.fifoPnlUnrealized / math.abs(pos.costBasisMoney)) .. " %"}}
              --userdata = {{key="_profit",value=string.format("%.02f", pos.fifoPnlUnrealized) .. " USD / " .. string.format("%.05f", 100/pos.costBasisMoney*pos.positionValue-100) .. " %"}}

          }

      end
      -- Return balance and array of transactions.
      return {
          securities = securities
      }
  elseif account.accountNumber == "2" then
      local summary = parseBlock(statementContent, 'EquitySummaryInBase')
      local cash = 0
      for p in summary:gmatch("<EquitySummaryByReportDateInBase(.-)/>") do
          print(p)
          local pos = parseargs(p)
          cash = pos.cash
      end
      --  array of transactions.
      local summary = parseBlock(statementContent, 'StmtFunds')
      local transactions = {}
      if summary then
          for p in summary:gmatch("<StatementOfFundsLine(.-)/>") do
              --print(p)
              local sm = parseargs(p)
              print(#transactions,sm.transactionID,sm.reportDate,sm.settleDate,sm.description,sm.activityDescription,sm.amount,sm.activityCode)
              if sm.activityCode  ~=  'ADJ' then
                  transactions[#transactions + 1] = {
                      name=sm.description,
                      amount=sm.amount,
                      currency="USD",
                      bookingDate=stringToTimestamp(sm.reportDate),
                      valueDate=stringToTimestamp(sm.settleDate),
                      transactionCode=sm.transactionID,
                      purpose=sm.activityDescription,
                      bookingText=sm.activityCode
                  }
              end
          end
      end
      -- Return balance and array of transactions.
      --print(JSON():set(transactions):json())
      return {
          balance = cash,
          transactions = transactions
      }
  end
end

function EndSession()
  -- Logout.
end

