<%
-- Enable localization
gettext.textdomain('webui-core')

local triesbeforemsg = 3
local content_helper = require("web.content_helper")

local cui = {
  defaultuser = "uci.web.uiconfig.@uidefault.defaultuser",
  nsplink = "uci.web.uiconfig.@uidefault.nsplink",
  adusrname = "uci.web.user.@usr_admin.name",
  legacysalt = "uci.web.user.@usr_admin.legacy_salt",
}
content_helper.getExactContent(cui)

local function createPwdLabel(desc)
    local html = {
        string.format([[
            <div class="control-group">
                <label>
                  <div class="label-icon">
                    <i class="icon-large"></i>
                  </div>
                </label>
                %s
            </div>
        ]], desc),
    }
    return html
end

local dm = require("datamodel")
if ngx.req.get_method() == "POST" then
  local post_args = ngx.req.get_post_args()
  local ret = false

  --if the post is to reset password, it means the legacy_salt should be reset
  if post_args.resetpass then
    ret = ngx.ctx.session:changePassword(post_args.salt, post_args.verifier)
    if ret then
      dm.set("uci.web.user.@usr_admin.legacy_salt", "")
      dm.apply()
    end
  end
end
%>
<!DOCTYPE HTML>
<%= string.format('<html lang="%s">', gettext.language()) %>
<head>
    <meta charset="UTF-8">
    <meta name="CSRFtoken" content="<%= ngx.ctx.session:getCSRFtoken() %>">
    <link href="/css/gw.css" rel="stylesheet">
    <!--[if IE 7]><link rel="stylesheet" href="/css/font-awesome-ie7.css"><![endif]-->
    <script src="/js/main-min.js" ></script>
    <!--[if lt IE 9]> <script src="/js/media-min.js"></script> <![endif]-->
    <script src="/js/srp-min.js" ></script>
    <title><%= T"Change password" %></title>
</head>
<body>
  <div class="container">
    <div class="logo-technicolor"><a href="<%= cui.nsplink %>" target="_blank"><img src="/img/logo.gif"></a></div>
    <div class="row">
      <div class="offset4 span4">
        <div class="login">
        <form class="form-horizontal">
          <fieldset>
                <h2><%= T"Change password" %></h2>
            <div id="erroruserpass" class="alert alert-error hide">
               <strong><%= T"Invalid Password" %></strong>
            </div>

            <%= createPwdLabel(T"Your old password") %>
            <div class="control-group">
                <label for="srp_password"><div class="label-icon">
                    <i class="icon-lock icon-large"></i>
                </div></label>
                <input class="span3" type="password" id="srp_password" autofocus><br><br>
            </div>
            <!-- HIDE WARNING - NOT USED IN DEFAULT CUSTO
            <div id="defaultpassword" class="alert alert-info hide">
                <%= T"If you haven't changed it, the default password can be found on the sticker under your gateway (it's called <strong>\"access code\"</strong>)" %>
            </div>
            -->
            <%= createPwdLabel(T"Your new password") %>
            <div class="control-group">
                <label for="srp_password_new_1"><div class="label-icon"><i class="icon-lock icon-large"></i></div></label>
                <input class="span3" type="password" id="srp_password_new_1"><br><br>
            </div>
            <%= createPwdLabel(T"Repeat new password") %>
            <div class="control-group">
                <label for="srp_password_new_2"><div class="label-icon"><i class="icon-lock icon-large"></i></div></label>
                <input class="span3" type="password" id="srp_password_new_2"><br><br>
            </div>
            <div class="pull-right">
                <a href="/" class="btn btn-primary btn-large"><%= T"Cancel" %></a>
                &nbsp;
                <div id="change-my-pass" class="btn btn-primary btn-large"><%= T"Change password" %></div>
            </div>
          </fieldset>
        </form>
      </div>
      </div>
    </div>
    <div class="row"><div class="copyright span12"><p>&copy; Technicolor 2014</p></div></div>
  </div>
<script>
$(document).ready(
  function() {
    var triesbeforemsg = <%= triesbeforemsg %>;
    var tries = 0;

    function display_error()
    {
        $("#change-my-pass").text('<%= T"Change password" %>');
        $("#erroruserpass").show();
        $(".control-group").addClass("error");
        tries++;
        if(triesbeforemsg > 0 && tries >= triesbeforemsg) {
            $("#defaultpassword").show();
        }
    }

    // Set the focus on the first input field
    $('form:first *:input[type!=hidden]:first').focus();
    // Handle press of enter. Could be handled by adding a hidden input submit but
    // this requires a lot of css tweaking to get it right since display:none does
    // not work on every browser. So go for the js way
    $('form input').keydown(function(e) {
        if(e.which == 13 || e.which == 10) {
            e.preventDefault();
            $("#change-my-pass").click();
        }
    });

    $("#change-my-pass").on("click", function () {
      if ($("#srp_password_new_1")[0].value != $("#srp_password_new_2")[0].value) {
        display_error();
        return false;
      }
      $(this).text('<%= T"Updating" %>');
      var password = $("#srp_password")[0].value;

      //to get the legacy_salt & is not null, and confirm the username is adminusername, do migration
      var legacysalt = "<%= cui.legacysalt %>";
      var aduser = "<%= cui.adusrname %>";
      if (("" != legacysalt) && (aduser == '<%= ngx.ctx.session:getusername() %>'))
      {
        var hashObj = new jsSHA((legacysalt+tch.stringToHex(password)), "HEX");
        password = hashObj.getHash("SHA-1", "HEX");
      }
      var srp = new SRP();
      srp.success = function() {
      //if the legacy_salt is not null, and the user is admin, should reset the legacy_salt for migration
        if (("" != legacysalt) && ('<%= ngx.ctx.session:getusername() %>' == aduser))
        {
          srp.generateSaltAndVerifierTheCallback('<%= ngx.ctx.session:getusername() %>', $("#srp_password_new_1")[0].value, function(salt, verStr) {
            $.post("/password.lp", { CSRFtoken:$("meta[name=CSRFtoken]").attr("content"), salt:salt, verifier:verStr, resetpass:"1" },
            function reloadPage(){
              window.location = "/";
            });
          });
        }
        else
        {
          srp.generateSaltAndVerifier("/password", '<%= ngx.ctx.session:getusername() %>', $("#srp_password_new_1")[0].value);
        }
      }
      srp.passwordchanged = function() {
        //if the legacysalt is null or the user is not admin, reload
        if (!(("" != legacysalt) && ('<%= ngx.ctx.session:getusername() %>' == aduser)))
        {
          window.location = "/";
        }
      }
      srp.error_message = function() {
        display_error();
      }
      srp.identify("/password", '<%= ngx.ctx.session:getusername() %>', password);
    });
  })
</script>
</body>
</html>
