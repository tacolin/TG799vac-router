<%
-- Localization
gettext.textdomain('webui-core')

local ngx = ngx
local proxy = require("datamodel")
local ui_helper = require("web.ui_helper")
local post_helper = require("web.post_helper")
local content_helper = require("web.content_helper")
local pairs, table = pairs, table
local format = string.format
local numOfPings = "2"
local refresh = 2
local restarted = false
local xtmintf = proxy.getPN("uci.wanatmf5loopback.",true)


local xdsl_params = {
  dsl_status = "sys.class.xdsl.@line0.Status"
}

content_helper.getExactContent(xdsl_params)

local content_uci = {
  wan_proto = "uci.network.interface.@wan.proto",
  wan_auto = "uci.network.interface.@wan.auto",
  wan_devices = "uci.network.interface.@wan.device"
}
content_helper.getExactContent(content_uci)
if content_uci["wan_auto"] ~= "0" then
    content_uci["wan_auto"] = "1" -- default is enabled, so if absent, consider it's enabled
end

local content_rpc_wan = {
  wan_ppp_state = "rpc.network.interface.@wan.ppp.state",
  wan_ppp_error = "rpc.network.interface.@wan.ppp.error",
  wan_up = "rpc.network.interface.@wan.up",
  wan_available = "rpc.network.interface.@wan.available",
  wan_ipaddr = "rpc.network.interface.@wan.ipaddr",
  dns_servers = "rpc.network.interface.@wan.dnsservers",
  nexthop_state = "rpc.network.interface.@wan.nexthop_ping",
  dnsserver1_state = "rpc.network.interface.@wan.dnsserver1_ping",
  dnsserver2_state = "rpc.network.interface.@wan.dnsserver2_ping",
}

content_helper.getExactContent(content_rpc_wan)

local content_rpc_wan6 = {
  wan6_ip6addr = "rpc.network.interface.@wan6.ip6addr",
  dns_servers_ipv6 = "rpc.network.interface.@wan6.dnsservers",
  nexthop_state_ipv6 = "rpc.network.interface.@wan6.nexthop_ping",
  dnsserver1_state_ipv6 = "rpc.network.interface.@wan6.dnsserver1_ping",
  dnsserver2_state_ipv6 = "rpc.network.interface.@wan6.dnsserver2_ping"
}
content_helper.getExactContent(content_rpc_wan6)


local num_servers = 0
if content_rpc_wan["dns_servers"] ~= "" then
  num_servers = tonumber(select(2, string.gsub(content_rpc_wan["dns_servers"], ",",","))) + 1
end
local num_servers_ipv6 = 0
if content_rpc_wan6["dns_servers_ipv6"] ~= "" then
  num_servers_ipv6 = tonumber(select(2, string.gsub(content_rpc_wan6["dns_servers_ipv6"], ",",","))) + 1
end

proxy.get("uci.xtm.") ---workaround problem in transformer DE3058

local function restartTest()
  for _,v in ipairs(xtmintf) do
    proxy.set( v["path"].."NumberOfRepetitions", numOfPings)
    proxy.set(v["path"].."DiagnosticsState", "Requested")
  end
   proxy.set("rpc.network.interface.@wan.nexthop_ping",
                           "Requested")
  if num_servers >= 1 then
    proxy.set("rpc.network.interface.@wan.dnsserver1_ping",
                             "Requested")
  end
  if num_servers >= 2 then
    proxy.set("rpc.network.interface.@wan.dnsserver2_ping",
                             "Requested")
  end
  proxy.set("rpc.network.interface.@wan6.nexthop_ping",
                           "Requested")
  if num_servers_ipv6 >= 1 then
    proxy.set("rpc.network.interface.@wan6.dnsserver1_ping",
                             "Requested")
  end
  if num_servers_ipv6 >= 2 then
    proxy.set("rpc.network.interface.@wan6.dnsserver2_ping",
                             "Requested")
  end
  proxy.apply()
  restarted = true
end

local ppp_status, ppp_text_status
if (content_uci.wan_proto == "pppoe" or content_uci.wan_proto == "pppoa") and content_uci.wan_auto ~= "0" then
-- PPP enabled
  ppp_status = content_rpc_wan.wan_ppp_state
  if ppp_status == "" then
    ppp_status = "connecting"
    ppp_text_status = T"PPP connecting"
  else
    ppp_status = "connected"
    ppp_text_status = T"PPP connected"
  end
  if content_rpc_wan.wan_ppp_error ~= "" and content_rpc_wan.wan_ppp_error ~= "USER_REQUEST" then
    local ppp_status_map = {
      ["AUTH_TOPEER_FAILED"] = T"PPP authentication failed",
      ["NEGOTIATION_FAILED"] = T"PPP negotiation failed",
    }
    ppp_text_status = ppp_status_map[content_rpc_wan.wan_ppp_error] or T"PPP error"
  end
else
-- PPP disabled
  ppp_text_status = T"PPP disconnected"
  ppp_status = "disconnected"
end

local atmping_state = {}
for _,v in ipairs(xtmintf) do
  atmping_state[#atmping_state +1] = proxy.get(v["path"].."DiagnosticsState")[1].value
end

-- to handle state that can arise due to async logic
if(content_rpc_wan["dnsserver1_state"] == "Waiting" and
   content_rpc_wan["nexthop_state"] == "Waiting" and
   content_rpc_wan["dnsserver2_state"] == "Waiting" and
   content_rpc_wan6["nexthop_state_ipv6"] == "Waiting" and
   content_rpc_wan6["dnsserver1_state_ipv6"] == "Waiting" and
   content_rpc_wan6["dnsserver2_state_ipv6"] == "Waiting") then
  restartTest()
end

-- This code will be triggered by get and post of the button
local post_content
if ngx.var.request_method == "GET" then
  restartTest()
else
  if ngx.var.request_method == "POST" then
    post_content = ngx.req.get_post_args()
    if post_content["operation"] == "RESTART" then
      restartTest()
    end
  end
end

local atmping_refresh_stop = true

for i=1,#atmping_state do
  if atmping_state[i] == "Requested"  or atmping_state[i] == "None" then
    atmping_refresh_stop = false
  end
end

local function checkState(states)
  local retval = true
  for _,state in ipairs(states) do
     retval = (state ~= "Requested" and state ~= "Waiting" and state ~= "None" and retval)
  end
  return retval
end

--This code will stop the refresh when all results are available
if( num_servers >= 2 and num_servers_ipv6 >= 2 and
   atmping_refresh_stop and
   checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
               content_rpc_wan["dnsserver2_state"], content_rpc_wan6["nexthop_state_ipv6"],
               content_rpc_wan6["dnsserver1_state_ipv6"], content_rpc_wan6["dnsserver2_state_ipv6"]}) and
   restarted ~= true) then
     refresh = nil
elseif (num_servers == 1 and num_servers_ipv6 >= 2 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
              content_rpc_wan6["nexthop_state_ipv6"], content_rpc_wan6["dnsserver1_state_ipv6"],
              content_rpc_wan6["dnsserver2_state_ipv6"]}) and
  restarted ~= true) then
    refresh = nil
elseif (num_servers == 0 and num_servers_ipv6 >= 2 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan6["nexthop_state_ipv6"],
              content_rpc_wan6["dnsserver1_state_ipv6"], content_rpc_wan6["dnsserver1_state_ipv6"],
              content_rpc_wan6["dnsserver2_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
elseif (num_servers == 0 and num_servers_ipv6 == 1 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan6["nexthop_state_ipv6"],
              content_rpc_wan6["dnsserver1_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
elseif(num_servers >= 2 and num_servers_ipv6 == 1 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
              content_rpc_wan["dnsserver2_state"], content_rpc_wan6["nexthop_state_ipv6"],
              content_rpc_wan6["dnsserver1_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
elseif(num_servers == 1 and num_servers_ipv6 == 1 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
              content_rpc_wan6["nexthop_state_ipv6"], content_rpc_wan6["dnsserver1_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
elseif(num_servers == 1 and num_servers_ipv6 == 0 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
              content_rpc_wan6["nexthop_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
elseif(num_servers >= 2 and num_servers_ipv6 == 0 and
  atmping_refresh_stop and
  checkState({content_rpc_wan["nexthop_state"], content_rpc_wan["dnsserver1_state"],
              content_rpc_wan["dnsserver2_state"], content_rpc_wan6["nexthop_state_ipv6"]}) and
  restarted ~= true) then
  refresh = nil
end

local uri = ngx.var.uri
local help_link = { href="/help/index.html?anchor=" .. uri:match("/([^/]+)%.lp") }
%>

<% =ui_helper.createHeader("Diagnostics Connection", false, false, refresh, help_link) %>

<div class="modal-body update">
<%
    local lp = require("web.lp")
    lp.setpath("/www/snippets/")
    lp.include("tabs-diagnostics.lp")
%>

<form class="form-horizontal" method="post" action="modals/diagnostics-connection-modal.lp">
    <fieldset id="diagnostics-connection-tab">
        <legend>Connection Check</legend>

<%
local html = {}

-- Restart test button
local restart_all_tests = {
    controls = {
      class = "restart_all_tests"
    },
    button = {
      ["data-name"] = "operation",
      ["data-value"] = "RESTART"
    }
}

html[#html+1] = ui_helper.createButton(T"Restart all Tests", T"Restart", "icon-reply", restart_all_tests)

local attributes = {
    span = {
        class = "span5",
    }
}

if string.match(content_uci["wan_devices"],"eth%d") ~= nil then
    -- If ethernet wan, show status
    if content_rpc_wan["wan_up"] == "1" then
        html[#html+1] = ui_helper.createLabel(T"Eth Wan Enable", format("%s %s","<i class=\"icon-ok icon-large green\"></i> ",T"Interface Enabled"), attributes)
    else
        html[#html+1] = ui_helper.createLabel(T"Eth Wan Enable", format("%s %s","<i class=\"icon-ban-circle icon-large red\"></i> ",T"Interface Disabled"), attributes)
    end

    if content_rpc_wan["wan_available"] == "1" then
        html[#html+1] = ui_helper.createLabel(T"Eth Wan Available", format("%s %s","<i class=\"icon-ok icon-large green\"></i> ",T"Link Up"), attributes)
    else
        html[#html+1] = ui_helper.createLabel(T"Eth Wan Available", format("%s %s","<i class=\"icon-ban-circle icon-large red\"></i> ",T"Link Down"), attributes)
    end
else
    -- DSL status
    local attributes = { span = { class = "span8" } }
    local statusIconDSL

    if xdsl_params["dsl_status"] == "Up" then
        statusIconDSL = "<i class=\"icon-ok icon-large green\"></i> "
    else
        statusIconDSL = "<i class=\"icon-ban-circle icon-large red\"></i> "
    end
    html[#html+1] = ui_helper.createLabel(T"DSL Status",format("%s %s",statusIconDSL, xdsl_params["dsl_status"]), attributes)

    --Check ATM ping and display the results if relevant
    local statusIconAtmPing = {}
    local explanationAtmPing = {}
    for k,v in ipairs(xtmintf) do
        local statusAtmPingTest = proxy.get(v["path"].."DiagnosticsState")

        if statusAtmPingTest  then
            statusAtmPingTest = statusAtmPingTest[1].value
            if statusAtmPingTest == "Complete" then
                local ret = proxy.get(v["path"].."NumberOfRepetitions", v["path"].."SuccessCount")
                local numRep =  ret[1].value
                local SuccessCount =  ret[2].value
                if numRep ==  SuccessCount then
                    statusIconAtmPing[k] = "<i class=\"icon-ok icon-large green\"></i> "
                    explanationAtmPing[k] = T"Success"
                else
                    statusIconAtmPing[k] = "<i class=\"icon-ban-circle icon-large red\"></i>"
                    explanationAtmPing[k] = T"Not all ping request were answered"
                end
            else
                if statusAtmPingTest == T"Requested" then
                    statusIconAtmPing[k] = "<i class=\"icon-asterisk icon-large blue\"></i> "
                    explanationAtmPing[k] = T"Ongoing"
                else
                    statusIconAtmPing[k] = "<i class=\"icon-ban-circle icon-large red\"></i>"
                    explanationAtmPing[k] = T"Failed"
                end
            end
        else
            statusIconAtmPing[k] = "<i class=\"icon-ban-circle icon-large red\"></i>"
            explanationAtmPing[k] = T"Not Connected"
        end

        local xtm_intf_name = string.gsub(v["path"],"uci.wanatmf5loopback.@","")
        local vpi = proxy.get("uci.xtm.atmdevice.@"..xtm_intf_name.."vpi")[1].value
        local vci = proxy.get("uci.xtm.atmdevice.@"..xtm_intf_name.."vci")[1].value
        html[#html+1] = ui_helper.createLabel(T"ATM Ping Test", format("%s PVC %s/%s %s", statusIconAtmPing[k], vpi, vci, explanationAtmPing[k], attributes))
    end
end
-- Show PPP status if relevant
if string.find(content_uci["wan_proto"], "ppp") == 1 then
    if ppp_status == "connected" then
        html[#html+1] = ui_helper.createLabel(T"PPP status", format("%s %s","<i class=\"icon-ok icon-large green\"></i> ", ppp_text_status), attributes)
    else
        html[#html+1] = ui_helper.createLabel(T"PPP status", format("%s %s","<i class=\"icon-ban-circle icon-large red\"></i> ", ppp_text_status), attributes)
    end
end

-- Show current IPv4 address
if (content_rpc_wan["wan_ipaddr"] and content_rpc_wan["wan_ipaddr"] ~= "") then
    html[#html+1] = ui_helper.createLabel(T"IP Version 4 Address", format("%s %s", "<i class=\"icon-ok icon-large green\"></i> ", content_rpc_wan["wan_ipaddr"]), attributes)
else
    html[#html+1] = ui_helper.createLabel(T"IP Version 4 Address", format("%s %s", "<i class=\"icon-ban-circle icon-large red\"></i> ",T"No Address Assigned"), attributes)
end

-- Show current IPv6 address
if (content_rpc_wan6["wan6_ip6addr"] and content_rpc_wan6["wan6_ip6addr"] ~= "") then
    html[#html+1] = ui_helper.createLabel(T"IP Version 6 Address", format("%s %s","<i class=\"icon-ok icon-large green\"></i> ", content_rpc_wan6["wan6_ip6addr"]), attributes)
else
    html[#html+1] = ui_helper.createLabel(T"IP Version 6 Address", format("%s %s","<i class=\"icon-ban-circle icon-large red\"></i> ",T"No Address Assigned"), attributes)
end

local function getStatus(param)
    local statusIcon
    local explanation
    local statusTest = proxy.get(param)
    if statusTest then
        statusTest = statusTest[1].value
        if statusTest == "Success" then
            statusIcon = "<i class=\"icon-ok icon-large green\"></i> "
            explanation = T"Success"
        else
            if (statusTest == "Requested" or  statusTest == "Waiting")then
                statusIcon = "<i class=\"icon-asterisk icon-large blue\"></i> "
                explanation = T"Ongoing"
                --triggers the state machine do not remove
                proxy.set("rpc.network.interface.@wan.status_ping_test","Done")
                proxy.apply()
            else
                statusIcon  = "<i class=\"icon-ban-circle icon-large red\"></i>"
                explanation = T"Not all pings were answered or not connected"
            end
        end
    return statusIcon, explanation
    end
    return "<i class=\"icon-question-sign icon-large red\"></i>", T"Unknown state"
end

-- Next functions use the ipping functionality, since it is a shared
-- resource, a state machine is required.
-- show ping result over IPv4
local statusIconNextHopPing
local explanationNextHopPing
statusIconNextHopPing, explanationNextHopPing = getStatus("rpc.network.interface.@wan.nexthop_ping")

html[#html+1] = ui_helper.createLabel(T"Next Hop Ping", format("%s %s", statusIconNextHopPing, explanationNextHopPing), attributes)

if num_servers >= 1 then
    local statusIconDnsServer1Ping
    local explanationDnsServer1Ping
    statusIconDnsServer1Ping, explanationDnsServer1Ping =  getStatus("rpc.network.interface.@wan.dnsserver1_ping")
    html[#html+1] = ui_helper.createLabel(T"First DNS Server Ping", format("%s %s", statusIconDnsServer1Ping, explanationDnsServer1Ping), attributes)
end
if num_servers >= 2 then
    local statusIconDnsServer2Ping
    local explanationDnsServer2Ping
    statusIconDnsServer2Ping, explanationDnsServer2Ping = getStatus("rpc.network.interface.@wan.dnsserver2_ping")
    html[#html+1] = ui_helper.createLabel(T"Second DNS Server Ping", format("%s %s", statusIconDnsServer2Ping, explanationDnsServer2Ping), attributes)
end

-- Show ping result over IPv6 if relevant
if (content_rpc_wan6["wan6_ip6addr"] and content_rpc_wan6["wan6_ip6addr"] ~= "") then
    local statusIconNextHopPing_ipv6
    local explanationNextHopPing_ipv6
    statusIconNextHopPing_ipv6, explanationNextHopPing_ipv6 = getStatus("rpc.network.interface.@wan6.nexthop_ping")

    html[#html+1] = ui_helper.createLabel(T"Next Hop Ping IPV6", format("%s %s", statusIconNextHopPing_ipv6, explanationNextHopPing_ipv6), attributes)

    if num_servers_ipv6 >= 1 then
        local statusIconDnsServer1Ping_ipv6
        local explanationDnsServer1Ping_ipv6
        statusIconDnsServer1Ping_ipv6, explanationDnsServer1Ping_ipv6 = getStatus("rpc.network.interface.@wan6.dnsserver1_ping")
        html[#html+1] = ui_helper.createLabel(T"First DNS Server IPV6 Ping", format("%s %s", statusIconDnsServer1Ping_ipv6, explanationDnsServer1Ping_ipv6), attributes)
    end

    if num_servers_ipv6 >= 2 then
        local statusIconDnsServer2Ping_ipv6
        local explanationDnsServer2Ping_ipv6
        statusIconDnsServer2Ping_ipv6, explanationDnsServer2Ping_ipv6 = getStatus("rpc.network.interface.@wan6.dnsserver2_ping")
        html[#html+1] = ui_helper.createLabel(T"Second DNS Server IPV6 Ping", format("%s %s", statusIconDnsServer2Ping_ipv6, explanationDnsServer2Ping_ipv6), attributes)
    end
end
ngx.print (html)
%>

        </fieldset>
    </form>
</div>

<% ngx.print(ui_helper.createFooter()) %>
