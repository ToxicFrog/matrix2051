-- Matrix2051 client script for Weechat.
-- M51 speaks IRCv3 to the client, so this is all UX features, not protocol.
-- It is designed primarily for my use case, i.e. heavy use of bridges on the
-- Matrix side, although some features will be generally useful.
--
-- It requires some server-side support not present in mainline M51; in particular
-- it expects channel names for bridged channels to be of the form "#name:network.protocol"
-- rather than the raw mxid, and channel names for DM channels to start with @.
--
-- Features:
-- - installs filters for M51 invite and delete notices, which can be very spammy
-- - renders messages from Matrix users using their display name rather than their mxid
-- - renders replies with a leading ⮬ icon
-- - creates a server buffer for each bridged network (bridges that don't have
--   a concept of networks, like googlechat, will get one for the whole protocol)
-- - sets the 'server' localvar for bridged rooms to match the server buffer
-- - sets the 'is_m51' localvar for all matrix rooms so they can be found even
--   when the server localvar has changed


-- Script configuration --

-- Name of local M51 server in weechat configuration. Currently no support for
-- multiple servers.
local M51_SERVER = 'matrix'

-- Signals to automatically rescan buffers after.
local SIGNALS = { 'buffer_opened', 'buffer_closed', 'buffer_renamed' }

-- Filters to install to hide spammy messages from M51.
local FILTERS = {
  deletes = 'irc.@S.* irc_notice+nick_server. deleted an event';
  invites = 'irc.server.@S irc_invite .*';
}

-- Triggers to install to annotate messages from M51.
local TRIGGERS = {
  dm_notify = [[
    line formatted;irc.@S.@*;notify_message+irc_privmsg
    ""
    s/,notify_message,/,notify_private,/tags
  ]];
  display_name = [[
    modifier weechat_print
    "${is_m51} && ${tg_tag_irc_+draft/display-name}"
    "s!^[^\t]+!${info:nick_color,${tg_tag_irc_+draft/display-name}}${tg_tag_irc_+draft/display-name}"
  ]];
  red_replies = [[
    modifier weechat_print
    "${is_m51} && ${tg_tag_irc_+draft/reply}"
    "s/^/⮬ "
  ]];
}

-- No user serviceable parts below this line --

local SCRIPT_NAME     = "m51weechat"
local SCRIPT_AUTHOR   = "ToxicFrog <toxicfrog@ancilla.ca>"
local SCRIPT_VERSION  = "1"
local SCRIPT_LICENSE  = "MIT"
local SCRIPT_DESC     = "Channel organization helper for matrix2051 servers"

local w = weechat
local hooks = {}
local headers = {}
local imask = false

local function printf(...)
  w.print('', string.format(...))
end

local function cmdf(...)
  w.print('', "Executing command: "..string.format(...))
  w.command('', string.format(...))
end

-- Turns a network name into a weechat fully qualified buffer name
local function header_bufname(network)
  return string.format('%s.m51.header', network)
end

local function header_start_gc()
  for k in pairs(headers) do headers[k] = false end
end

local function header_mark(network)
  headers[network] = true
end

local function header_sweep()
  for name,v in pairs(headers) do
    local buffer = w.buffer_search('lua', header_bufname(name))
    if not v then
      if buffer ~= '' then
        printf("Cleaning up old header %s", header_bufname(name))
        w.buffer_close(buffer)
      end
      headers[name] = nil
    elseif buffer == '' then
      printf("Creating new header %s", header_bufname(name))
      buffer = w.buffer_new(header_bufname(name), '','','','')
      if buffer ~= '' then
        w.buffer_set(buffer, 'localvar_set_server', name)
        w.buffer_set(buffer, 'localvar_set_plugin', 'irc')
        w.buffer_set(buffer, 'localvar_set_type', 'server')
        w.buffer_set(buffer, 'short_name', name)
      else
        printf("Error creating header buffer %s", header_bufname(name))
      end
    end
  end
  printf('header_sweep complete')
end

local function apply_localvars(name, network)
  local buffer = w.buffer_search('==', name)
  printf('Setting network of %s to %s', name, network)
  w.buffer_set(buffer, 'localvar_set_is_m51', 'true')
  w.buffer_set(buffer, 'localvar_set_server', network)
  header_mark(network)
end

function on_signal(data, signal, ctx)
  if imask then return end
  imask = true
  header_start_gc()
  local buflist = w.infolist_get('buffer', '', 'irc.'..M51_SERVER..'.*')
  while w.infolist_next(buflist) ~= 0 do
    local name = w.infolist_string(buflist, 'full_name')
    local network = name:match('[^:]*$')
    if network == 'gchat' or network:match('discord$') then
      apply_localvars(name, network)
    end
    -- w.print('', 'Buffer: '..network..'//'..name)
  end
  w.infolist_free(buflist)
  header_sweep()
  imask = false
end

local function on_init()
  if not w.register(SCRIPT_NAME, SCRIPT_AUTHOR, SCRIPT_VERSION, SCRIPT_LICENSE, SCRIPT_DESC, 'on_deinit', '') then return end
  -- Hook all signals and the manually invoked command
  for _,signal in ipairs(SIGNALS) do
    hooks[signal] = w.hook_signal(signal, 'on_signal', '')
  end
  hooks[0] = w.hook_command('m51', 'apply m51 helper variables', '', '', '', 'on_signal', '')

  -- Add filters and triggers
  for name,args in pairs(FILTERS) do
    args = args:gsub('@S', M51_SERVER):gsub('\n%s*', ' ')
    cmdf('/filter addreplace m51_%s %s', name, args)
  end
  for name,args in pairs(TRIGGERS) do
    args = args:gsub('@S', M51_SERVER):gsub('\n%s*', ' ')
    cmdf('/trigger addreplace m51_%s %s', name, args)
  end

  -- On-load configuration
  on_signal()
end

function on_deinit()
  imask = true
  for _,hook in pairs(hooks) do
    w.unhook(hook)
  end
  for name in pairs(FILTERS) do
    cmdf('/filter del m51_%s', name)
  end
  for name in pairs(TRIGGERS) do
    cmdf('/trigger del m51_%s', name)
  end
  header_start_gc()
  header_sweep()
end

on_init()
