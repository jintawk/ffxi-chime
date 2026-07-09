--[[
Copyright © 2026, Jintawk
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Chime nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL Jintawk BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

_addon.name = 'Chime'
_addon.author = 'Jintawk'
_addon.version = '1.1.1'
_addon.commands = {'chime', 'timer', 'tm'}

local config = require('config')
local slate = require('slate')

local defaults = {
    display = {
        pos = {x = 280, y = 140},
        bg = {alpha = 200, red = 12, green = 12, blue = 16, visible = true},
        flags = {draggable = true, bold = false},
        padding = 6,
        text = {
            font = 'Consolas',
            size = 11,
            alpha = 255, red = 245, green = 245, blue = 245,
            stroke = {width = 1, alpha = 180, red = 0, green = 0, blue = 0},
        },
    },
    bar = {show = true, width = 10, full = '█', empty = '░'},
    icons = {repeating = '↻', paused = '||'},
    label_width = 14,
    max_visible = 8,
    show_header = true,
    sound = {name = 'chime', repeats = 2, gap = 2.5},
    chat_alert = true,
    warn_at = 60,
    crit_at = 10,
    linger = 12,
    snooze = '5m',
    ui = {scale = 1, minimized = false},
    colors = {
        ok = {r = 120, g = 220, b = 140},
        warn = {r = 245, g = 215, b = 90},
        crit = {r = 255, g = 95, b = 95},
        crit_dim = {r = 150, g = 60, b = 60},
        done = {r = 255, g = 200, b = 80},
        flash = {r = 255, g = 255, b = 255},
        label = {r = 235, g = 235, b = 235},
        muted = {r = 140, g = 140, b = 145},
        dim = {r = 70, g = 70, b = 78},
        accent = {r = 120, g = 180, b = 255},
    },
}

local settings = config.load(defaults)

-------------------------------------------------------------------------------
-- Slate HUD scaffolding (libs/slate.lua)
-------------------------------------------------------------------------------

local UI_W  = 240
local ROW_H = 18
local CRIT_DIM = {150, 60, 60, 255}    -- dim phase of the critical flash

local ui = {
    built = false,
    panel = nil,
    rows = {},      -- pooled timer rows: {name, time, bar}
    extras = {},    -- pooled banner / overflow labels
}

local function build_ui()
    if ui.built then
        return
    end
    ui.built = true
    slate.set_scale(tonumber(settings.ui.scale) or 1)
    ui.panel = slate.Panel({
        x = settings.display.pos.x,
        y = settings.display.pos.y,
        w = UI_W,
        content_h = 40,
        title = 'CHIME',
        minimized = settings.ui.minimized,
        on_move = function(x, y)
            settings.display.pos.x = x
            settings.display.pos.y = y
            config.save(settings)
        end,
        on_minimize = function(min)
            settings.ui.minimized = min
            config.save(settings)
        end,
    })
end

local function ensure_rows(n)
    for i = #ui.rows + 1, n do
        local row = {
            name = slate.Label({size = 10, color = slate.color.text}),
            time = slate.Label({size = 10, font = slate.font.mono, color = slate.color.ok}),
            bar  = slate.Bar({w = 58, h = 10, text = false}),
        }
        ui.panel:add(row.name, 10, 0)
        ui.panel:add(row.time, 122, 0)
        ui.panel:add(row.bar, 172, 0)
        ui.rows[i] = row
    end
end

local function ensure_extras(n)
    for i = #ui.extras + 1, n do
        local lbl = slate.Label({size = 10, bold = true, color = slate.color.warn})
        ui.panel:add(lbl, 10, 0)
        ui.extras[i] = lbl
    end
end

local timers = {}        -- {name, duration, every, end_at, remaining, paused, repeating, command}
local finished = {}      -- ringing/lingering: {name, until_clock}
local last_done = nil    -- most recently finished, for snooze
local char_name = nil

local FALLBACK_SOUNDS = {'alarm', 'bell', 'chime', 'ding'}

-------------------------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------------------------

-- FFXI's chat log is Shift-JIS, not UTF-8. Any multi-byte UTF-8 character
-- sent to add_to_chat garbles into CJK glyphs. Chat output must be ASCII;
-- only the texts-library HUD can render unicode.
local CHAT_SUBS = {
    ['\226\128\148'] = '-',    -- em dash
    ['\226\128\147'] = '-',    -- en dash
    ['\226\134\146'] = '->',   -- right arrow
    ['\226\128\166'] = '...',  -- ellipsis
    ['\194\183'] = '-',        -- middle dot
}

local function chat_sanitize(s)
    for from, to in pairs(CHAT_SUBS) do
        s = s:gsub(from, to)
    end
    return (s:gsub('[\128-\255]', ''))
end

local function msg(text)
    windower.add_to_chat(207, '[Chime] ' .. chat_sanitize(text))
end

-- UTF-8 aware character count and substring (labels/icons may be multi-byte)
local function ulen(s)
    local _, n = s:gsub('[^\128-\191]', '')
    return n
end

local function usub(s, n)
    local count, i = 0, 1
    while i <= #s and count < n do
        local c = s:byte(i)
        i = i + ((c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1)
        count = count + 1
    end
    return s:sub(1, i - 1)
end

local function cs(c)
    return string.format('\\cs(%d,%d,%d)', c.r, c.g, c.b)
end
local CR = '\\cr'

-- 65 -> "1:05", 3700 -> "1:01:40"
local function fmt_clock(s)
    if s < 0 then s = 0 end
    s = math.floor(s)
    local h = math.floor(s / 3600)
    local m = math.floor(s % 3600 / 60)
    if h > 0 then
        return string.format('%d:%02d:%02d', h, m, s % 60)
    end
    return string.format('%d:%02d', m, s % 60)
end

-- 5400 -> "1h30m", 300 -> "5m", 45 -> "45s"
local function fmt_dur(s)
    s = math.floor(s)
    local h = math.floor(s / 3600)
    local m = math.floor(s % 3600 / 60)
    local sec = s % 60
    local out = ''
    if h > 0 then out = out .. h .. 'h' end
    if m > 0 then out = out .. m .. 'm' end
    if sec > 0 or out == '' then out = out .. sec .. 's' end
    return out
end

-------------------------------------------------------------------------------
-- Duration and time-of-day parsing
-------------------------------------------------------------------------------

local UNITS = {
    s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
    m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
    h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
}

-- "1h30m", "5m", "90s", "2.5m": whole token must be number+unit pairs
local function parse_combo(tok)
    local total, pos = 0, 1
    while pos <= #tok do
        local s_, e_, num, unit = tok:find('^(%d+%.?%d*)(%a+)', pos)
        if not s_ then return nil end
        local mult = UNITS[unit]
        if not mult then return nil end
        total = total + tonumber(num) * mult
        pos = e_ + 1
    end
    if total <= 0 then return nil end
    return total
end

-- "1:30" -> 90 (m:ss), "1:30:00" -> 5400 (h:mm:ss)
local function parse_clock(tok)
    local h, m, s = tok:match('^(%d+):(%d%d?):(%d%d?)$')
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    m, s = tok:match('^(%d+):(%d%d?)$')
    if m then
        return tonumber(m) * 60 + tonumber(s)
    end
    return nil
end

-- Consume duration tokens from tokens[start] onward.
-- Accepts: "5m" | "5 m" | "5 min" | "1h30m" | "1h 30m" | "1:30" | bare "5" (= minutes)
-- Returns total seconds and number of tokens consumed, or nil.
local function parse_duration(tokens, start)
    local total = 0
    local i = start
    local pending = nil
    while i <= #tokens do
        local tok = (tokens[i] or ''):lower()
        if pending then
            local mult = UNITS[tok]
            if mult then
                total = total + pending * mult
                pending = nil
                i = i + 1
            else
                break
            end
        else
            local num = tok:match('^(%d+%.?%d*)$')
            if num then
                pending = tonumber(num)
                i = i + 1
            else
                local v = parse_clock(tok) or parse_combo(tok)
                if v then
                    total = total + v
                    i = i + 1
                else
                    break
                end
            end
        end
    end
    if pending then
        if total == 0 then
            total = pending * 60    -- bare number means minutes
        else
            i = i - 1               -- trailing number belongs to the label
        end
    end
    if total <= 0 then return nil end
    return math.floor(total + 0.5), i - start
end

-- Signed variant for extend: "-30s" subtracts
local function parse_signed_duration(tokens, start)
    local first = tokens[start]
    if first and first:sub(1, 1) == '-' then
        local copy = {}
        for k, v in ipairs(tokens) do copy[k] = v end
        copy[start] = first:sub(2)
        local secs, consumed = parse_duration(copy, start)
        if secs then return -secs, consumed end
        return nil
    end
    return parse_duration(tokens, start)
end

-- "21:30", "9:30pm", "9pm", "9:30:00" -> epoch of next occurrence
local function parse_at(tokens, start)
    local tok = (tokens[start] or ''):lower()
    local consumed = 1
    local ampm = tok:match('([ap]m)$')
    if ampm then tok = tok:sub(1, #tok - 2) end
    if not ampm and tokens[start + 1] then
        local nxt = tokens[start + 1]:lower()
        if nxt == 'am' or nxt == 'pm' then
            ampm = nxt
            consumed = 2
        end
    end
    local h, m, s = tok:match('^(%d%d?):(%d%d):(%d%d)$')
    if not h then
        h, m = tok:match('^(%d%d?):(%d%d)$')
    end
    if not h then
        h = tok:match('^(%d%d?)$')
        if h and not ampm then return nil end   -- bare hour needs am/pm to be unambiguous
    end
    if not h then return nil end
    h, m, s = tonumber(h), tonumber(m) or 0, tonumber(s) or 0
    if h > 23 or m > 59 or s > 59 then return nil end
    if ampm == 'pm' and h < 12 then h = h + 12 end
    if ampm == 'am' and h == 12 then h = 0 end
    local t = os.date('*t')
    t.hour, t.min, t.sec = h, m, s
    local at = os.time(t)
    if at <= os.time() then at = at + 86400 end
    return at, consumed
end

-------------------------------------------------------------------------------
-- Timer core
-------------------------------------------------------------------------------

-- Active first (soonest ring first), paused at the bottom
local function sorted_timers()
    local list = {}
    for _, t in ipairs(timers) do list[#list + 1] = t end
    table.sort(list, function(a, b)
        if a.paused ~= b.paused then return b.paused end
        if a.paused then return a.remaining < b.remaining end
        return a.end_at < b.end_at
    end)
    return list
end

local function unique_name(base)
    if not base or base == '' then
        local n = 1
        while true do
            base = 'Timer ' .. n
            local taken = false
            for _, t in ipairs(timers) do
                if t.name:lower() == base:lower() then taken = true break end
            end
            if not taken then return base end
            n = n + 1
        end
    end
    local name, n = base, 2
    while true do
        local taken = false
        for _, t in ipairs(timers) do
            if t.name:lower() == name:lower() then taken = true break end
        end
        if not taken then return name end
        name = base .. ' (' .. n .. ')'
        n = n + 1
    end
end

-- Resolve "<index|name>" against the sorted list.
-- Returns timer, or nil + match count (0 = none, >1 = ambiguous)
local function find_timer(query)
    local list = sorted_timers()
    local n = tonumber(query)
    if n and list[n] then return list[n] end
    local q = query:lower()
    local prefix, sub = {}, {}
    for _, t in ipairs(list) do
        local name = t.name:lower()
        if name == q then return t end
        if name:sub(1, #q) == q then
            prefix[#prefix + 1] = t
        elseif name:find(q, 1, true) then
            sub[#sub + 1] = t
        end
    end
    if #prefix == 1 then return prefix[1] end
    if #prefix == 0 and #sub == 1 then return sub[1] end
    return nil, #prefix + #sub
end

-------------------------------------------------------------------------------
-- Persistence (survives //lua reload, zoning, crashes)
-------------------------------------------------------------------------------

local function data_file()
    return windower.addon_path .. 'data/timers_' .. (char_name or 'global') .. '.lua'
end

local function save_timers()
    pcall(windower.create_dir, windower.addon_path .. 'data')
    local f = io.open(data_file(), 'w')
    if not f then return end
    f:write('return {\n')
    for _, t in ipairs(timers) do
        f:write(string.format(
            '    {name = %q, duration = %d, every = %s, end_at = %s, remaining = %s, paused = %s, repeating = %s, command = %s},\n',
            t.name, t.duration,
            t.every and tostring(t.every) or 'nil',
            t.paused and 'nil' or tostring(t.end_at),
            t.paused and tostring(t.remaining) or 'nil',
            tostring(t.paused or false), tostring(t.repeating or false),
            t.command and string.format('%q', t.command) or 'nil'))
    end
    f:write('}\n')
    f:close()
end

local function play_alert(single)
    local name = settings.sound.name
    if not name or name == 'off' or name == 'none' then return end
    local path = windower.addon_path .. 'sounds/' .. name .. '.wav'
    windower.play_sound(path)
    if not single then
        local repeats = math.floor(tonumber(settings.sound.repeats) or 1)
        local gap = tonumber(settings.sound.gap) or 2.5
        for i = 1, repeats - 1 do
            coroutine.schedule(function() windower.play_sound(path) end, i * gap)
        end
    end
end

local function ring(t)
    last_done = {name = t.name, duration = t.duration}
    finished[#finished + 1] = {name = t.name, until_clock = os.clock() + (tonumber(settings.linger) or 12)}
    if settings.chat_alert then
        msg(string.format("Time's up: %s (%s).", t.name, fmt_dur(t.duration)))
    end
    play_alert()
    if t.command then
        -- send_command speaks Windower console syntax, where game input needs
        -- the 'input' prefix; a leading slash is unambiguously a game command,
        -- so add the prefix for the user.
        local cmd = t.command
        if cmd:sub(1, 1) == '/' then
            cmd = 'input ' .. cmd
        end
        windower.send_command(cmd)
    end
end

local function restore_timers()
    local loader = loadfile(data_file())
    if not loader then return end
    local ok, saved = pcall(loader)
    if not ok or type(saved) ~= 'table' then return end
    local now = os.time()
    for _, s in ipairs(saved) do
        if type(s) == 'table' and s.name and s.duration then
            if s.paused then
                timers[#timers + 1] = {
                    name = s.name, duration = s.duration, every = s.every,
                    remaining = s.remaining or s.duration, paused = true,
                    repeating = s.repeating, command = s.command, end_at = 0,
                }
            elseif s.end_at and s.end_at > now then
                timers[#timers + 1] = {
                    name = s.name, duration = s.duration, every = s.every,
                    end_at = s.end_at, paused = false,
                    repeating = s.repeating, command = s.command,
                }
            elseif s.repeating and s.end_at then
                local every = s.every or s.duration
                local missed = math.ceil((now - s.end_at) / every)
                local end_at = s.end_at + missed * every
                if end_at <= now then end_at = now + every end
                timers[#timers + 1] = {
                    name = s.name, duration = every, every = every,
                    end_at = end_at, paused = false,
                    repeating = true, command = s.command,
                }
                msg(string.format('%s rang %d time%s while you were away - next at %s.',
                    s.name, missed, missed == 1 and '' or 's', os.date('%H:%M:%S', end_at)))
            elseif s.end_at then
                msg(string.format('%s finished %s ago (while you were away).',
                    s.name, fmt_dur(now - s.end_at)))
                last_done = {name = s.name, duration = s.duration}
                play_alert(true)
            end
        end
    end
    save_timers()
end

local function add_timer(seconds, label, opts)
    opts = opts or {}
    local t = {
        name = unique_name(label),
        duration = seconds,
        every = opts.every,
        end_at = opts.end_at or (os.time() + seconds),
        paused = false,
        repeating = opts.repeating or false,
        command = opts.command,
    }
    timers[#timers + 1] = t
    save_timers()
    return t
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

local function render()
    build_ui()
    local now = os.time()
    local bright = math.floor(os.clock() * 2) % 2 == 0
    local lw = tonumber(settings.label_width) or 14
    local list = sorted_timers()
    local maxv = tonumber(settings.max_visible) or 8

    local rows = {}
    local shown, hidden = 0, 0
    for _, t in ipairs(list) do
        if shown >= maxv then
            hidden = hidden + 1
        else
            shown = shown + 1
            local rem = t.paused and t.remaining or (t.end_at - now)
            if rem < 0 then rem = 0 end
            rows[#rows + 1] = {t = t, rem = rem, clock = fmt_clock(rem)}
        end
    end

    local n_extras = #finished + (hidden > 0 and 1 or 0)
    ensure_rows(#rows)
    ensure_extras(n_extras)
    ui.panel:content_height(4 + (#rows + n_extras) * ROW_H + 4)

    local line = 0
    local extra_i = 0

    -- ringing / lingering banners first, flashing until they expire
    for _, f in ipairs(finished) do
        extra_i = extra_i + 1
        local lbl = ui.extras[extra_i]
        ui.panel:place(lbl, 10, 4 + line * ROW_H)
        lbl:text(f.name .. " - TIME'S UP!")
        lbl:color(bright and slate.color.warn or slate.color.title)
        line = line + 1
    end

    for i, row_data in ipairs(rows) do
        local t, rem = row_data.t, row_data.rem
        local frac = t.duration > 0 and rem / t.duration or 0
        if frac > 1 then frac = 1 end

        local col
        if t.paused then
            col = slate.color.text_faint
        elseif rem <= (tonumber(settings.crit_at) or 10) then
            col = bright and slate.color.bad or CRIT_DIM
        elseif rem <= (tonumber(settings.warn_at) or 60) then
            col = slate.color.warn
        else
            col = slate.color.ok
        end

        local label = t.name
        if ulen(label) > lw then
            label = usub(label, lw - 1) .. '…'
        end
        if t.repeating then
            label = label .. ' ' .. settings.icons.repeating
        elseif t.paused then
            label = label .. ' ' .. settings.icons.paused
        end

        local row = ui.rows[i]
        local ry = 4 + line * ROW_H
        ui.panel:place(row.name, 10, ry)
        ui.panel:place(row.time, 122, ry + 1)
        ui.panel:place(row.bar, 172, ry + 3)
        row.name:text(label)
        row.name:color(t.paused and slate.color.text_faint or slate.color.text)
        row.time:text(row_data.clock)
        row.time:color(col)
        if settings.bar.show then
            row.bar:set(frac, nil, t.paused and slate.color.track_off_hl or col)
        end
        line = line + 1
    end

    if hidden > 0 then
        extra_i = extra_i + 1
        local lbl = ui.extras[extra_i]
        ui.panel:place(lbl, 10, 4 + line * ROW_H)
        lbl:text('+' .. hidden .. ' more…')
        lbl:color(slate.color.text_faint)
    end

    -- pooled widget visibility for the current row count
    if ui.panel:visible() and not ui.panel:is_minimized() then
        for i = 1, #ui.rows do
            local v = i <= #rows
            ui.rows[i].name:visible(v)
            ui.rows[i].time:visible(v)
            ui.rows[i].bar:visible(v and settings.bar.show or false)
        end
        for i = 1, #ui.extras do
            ui.extras[i]:visible(i <= extra_i)
        end
    end
end

local function tick()
    local now = os.time()

    for i = #timers, 1, -1 do
        local t = timers[i]
        if not t.paused and t.end_at <= now then
            ring(t)
            if t.repeating then
                local every = t.every or t.duration
                t.duration = every
                t.end_at = t.end_at + every
                if t.end_at <= now then t.end_at = now + every end
                save_timers()
            else
                table.remove(timers, i)
                save_timers()
            end
        end
    end

    for i = #finished, 1, -1 do
        if os.clock() > finished[i].until_clock then
            table.remove(finished, i)
        end
    end

    local player = windower.ffxi.get_player()
    local visible = player ~= nil and player.status ~= 4
        and (#timers > 0 or #finished > 0)
    if visible then
        build_ui()
        if not ui.panel:visible() then
            ui.panel:show()
        end
        if not ui.panel:is_minimized() then
            render()
        end
    elseif ui.built and ui.panel:visible() then
        ui.panel:hide()
    end
end

local last_frame = 0
windower.register_event('prerender', function()
    local now = os.clock()
    if now - last_frame < 0.2 then return end
    last_frame = now
    tick()
end)

-------------------------------------------------------------------------------
-- Sounds
-------------------------------------------------------------------------------

local function available_sounds()
    local names = {}
    local ok, entries = pcall(windower.get_dir, windower.addon_path .. 'sounds')
    if ok and type(entries) == 'table' then
        for _, e in ipairs(entries) do
            local n = e:match('^(.+)%.wav$')
            if n then names[#names + 1] = n end
        end
    end
    if #names == 0 then
        for _, n in ipairs(FALLBACK_SOUNDS) do names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local SUBS = {
    add = 'add', start = 'add', new = 'add', a = 'add',
    at = 'at', ['@'] = 'at',
    ['repeat'] = 'repeat', every = 'repeat', rep = 'repeat', loop = 'repeat',
    list = 'list', ls = 'list', l = 'list',
    remove = 'remove', rm = 'remove', del = 'remove', delete = 'remove',
    cancel = 'remove', stop = 'remove',
    clear = 'clear', clearall = 'clear',
    pause = 'pause', hold = 'pause',
    resume = 'resume', unpause = 'resume',
    extend = 'extend', ext = 'extend', add_time = 'extend',
    snooze = 'snooze', z = 'snooze',
    sound = 'sound', sounds = 'sounds',
    test = 'test',
    set = 'set',
    pos = 'pos',
    save = 'save',
    help = 'help', h = 'help', ['?'] = 'help',
}

-- Split off a trailing "| windower command" and any -r/--repeat flags
local function extract_opts(args, start)
    local main, command, repeating = {}, nil, false
    local i = start
    while i <= #args do
        local tok = args[i]
        if tok == '|' then
            if i < #args then
                command = table.concat(args, ' ', i + 1)
            end
            break
        elseif tok == '-r' or tok == '--repeat' then
            repeating = true
            i = i + 1
        else
            main[#main + 1] = tok
            i = i + 1
        end
    end
    return main, command, repeating
end

local function announce_added(t)
    local when = os.date('%H:%M:%S', t.end_at)
    if t.repeating then
        msg(string.format('%s - every %s, first ring %s.', t.name, fmt_dur(t.every or t.duration), when))
    else
        msg(string.format('%s - %s, rings at %s.', t.name, fmt_dur(t.duration), when))
    end
end

local function cmd_add(args, start, force_repeat)
    local main, command, repeating = extract_opts(args, start)
    repeating = repeating or force_repeat or false
    local secs, consumed = parse_duration(main, 1)
    if not secs then
        msg('Could not read a duration. Try: //timer 5m Dinner  (also 90s, 1h30m, 1:30)')
        return
    end
    if secs > 360000 then
        msg('That is over 100 hours - was that a typo? (' .. fmt_dur(secs) .. ')')
        return
    end
    local label = table.concat(main, ' ', 1 + consumed)
    local t = add_timer(secs, label, {
        repeating = repeating,
        every = repeating and secs or nil,
        command = command,
    })
    announce_added(t)
end

local function cmd_at(args, start)
    local main, command, repeating = extract_opts(args, start)
    local at, consumed = parse_at(main, 1)
    if not at then
        msg('Could not read a time. Try: //timer at 21:30 Raid  (or 9:30pm)')
        return
    end
    local secs = at - os.time()
    local label = table.concat(main, ' ', 1 + consumed)
    local t = add_timer(secs, label, {
        end_at = at,
        repeating = repeating,
        every = repeating and 86400 or nil,   -- "at ... -r" = daily alarm
        command = command,
    })
    if repeating then
        msg(string.format('%s - daily at %s, first ring in %s.', t.name, os.date('%H:%M', at), fmt_dur(secs)))
    else
        msg(string.format('%s - rings at %s (in %s).', t.name, os.date('%H:%M:%S', at), fmt_dur(secs)))
    end
end

local function resolve_or_complain(query, verb)
    if query == '' then
        if #timers == 1 then return timers[1] end
        if #timers == 0 then
            msg('No timers running.')
        else
            msg('Which one? //timer ' .. verb .. ' <number|name>  (see //timer list)')
        end
        return nil
    end
    local t, count = find_timer(query)
    if not t then
        if count and count > 1 then
            msg('"' .. query .. '" matches ' .. count .. ' timers - be more specific or use its number.')
        else
            msg('No timer matching "' .. query .. '". See //timer list.')
        end
        return nil
    end
    return t
end

local function remove_timer_obj(t)
    for i, x in ipairs(timers) do
        if x == t then
            table.remove(timers, i)
            break
        end
    end
    save_timers()
end

local function cmd_list()
    local list = sorted_timers()
    if #list == 0 then
        msg('No timers. Start one: //timer 5m Tea')
        return
    end
    local now = os.time()
    for i, t in ipairs(list) do
        local rem = t.paused and t.remaining or (t.end_at - now)
        local extra = ''
        if t.repeating then extra = extra .. ' - repeats every ' .. fmt_dur(t.every or t.duration) end
        if t.paused then extra = extra .. ' - paused' end
        if t.command then extra = extra .. ' - then: ' .. t.command end
        msg(string.format('%d. %s - %s left of %s%s', i, t.name, fmt_clock(rem), fmt_dur(t.duration), extra))
    end
end

local SET_KEYS = 'sound, repeats, gap, warn, crit, linger, snooze, scale, bar, label, max, header, chat, icon_repeat, icon_pause'

local function cmd_set(key, val)
    key = (key or ''):lower()
    if val == nil or val == '' then
        msg('Usage: //timer set <key> <value>. Keys: ' .. SET_KEYS)
        return
    end
    local lval = val:lower()
    local on = lval == 'on' or lval == 'true' or lval == 'yes'
    local num = tonumber(val)

    if key == 'sound' then
        if lval == 'off' or lval == 'none' then
            settings.sound.name = 'off'
            msg('Sound off.')
        else
            local found = nil
            for _, n in ipairs(available_sounds()) do
                if n:lower() == lval then found = n break end
            end
            if not found then
                msg('Unknown sound "' .. val .. '". Available: ' .. table.concat(available_sounds(), ', '))
                return
            end
            settings.sound.name = found
            play_alert(true)
            msg('Sound: ' .. found .. '.')
        end
    elseif key == 'repeats' and num then
        settings.sound.repeats = math.max(1, math.min(10, math.floor(num)))
        msg('Alert plays ' .. settings.sound.repeats .. ' time(s).')
    elseif key == 'gap' and num then
        settings.sound.gap = math.max(0.5, num)
        msg('Gap between alert sounds: ' .. settings.sound.gap .. 's.')
    elseif key == 'warn' then
        local secs = parse_duration({val}, 1)
        if not secs then msg('Bad duration.') return end
        settings.warn_at = secs
        msg('Yellow warning under ' .. fmt_dur(secs) .. '.')
    elseif key == 'crit' then
        local secs = parse_duration({val}, 1)
        if not secs then msg('Bad duration.') return end
        settings.crit_at = secs
        msg('Red flash under ' .. fmt_dur(secs) .. '.')
    elseif key == 'linger' and num then
        settings.linger = math.max(1, num)
        msg("TIME'S UP banner lingers " .. settings.linger .. 's.')
    elseif key == 'snooze' then
        if not parse_duration({val}, 1) then msg('Bad duration.') return end
        settings.snooze = val
        msg('Default snooze: ' .. val .. '.')
    elseif key == 'scale' and num then
        settings.ui.scale = math.max(0.5, math.min(3, num))
        slate.set_scale(settings.ui.scale)
        msg('HUD scale ' .. settings.ui.scale .. '.')
    elseif key == 'size' or key == 'font' or key == 'bg' or key == 'barwidth' then
        msg('The HUD is styled by Slate now - use //timer set scale <0.5-3>.')
        return
    elseif key == 'bar' then
        settings.bar.show = on
        msg('Progress bars ' .. (on and 'on' or 'off') .. '.')
    elseif key == 'label' and num then
        settings.label_width = math.max(6, math.min(30, math.floor(num)))
        msg('Label width ' .. settings.label_width .. '.')
    elseif key == 'max' and num then
        settings.max_visible = math.max(1, math.floor(num))
        msg('Showing up to ' .. settings.max_visible .. ' timers.')
    elseif key == 'header' then
        settings.show_header = on
        msg('Header ' .. (on and 'on' or 'off') .. '.')
    elseif key == 'chat' then
        settings.chat_alert = on
        msg('Chat alerts ' .. (on and 'on' or 'off') .. '.')
    elseif key == 'icon_repeat' then
        settings.icons.repeating = val
        msg('Repeat icon: ' .. val)
    elseif key == 'icon_pause' then
        settings.icons.paused = val
        msg('Pause icon: ' .. val)
    else
        msg('Unknown setting "' .. key .. '". Keys: ' .. SET_KEYS)
        return
    end
    config.save(settings)
end

local function cmd_help()
    local lines = {
        'Chime - a kitchen timer. Durations: 5m, 90s, 1h30m, 1:30; bare number = minutes.',
        '//timer 5m Dinner            start a timer (add/start/new also work)',
        '//timer at 21:30 Raid        ring at a clock time (9:30pm works too)',
        '//timer repeat 10m Repop     repeating timer (or add -r to any timer)',
        '//timer 30s Pull | /p Go!    run a command when it rings:',
        '   starts with / = game input (chat, JA, /echo); else a Windower',
        '   console command (lua, send, exec) - same as typing in the console',
        '//timer list                 show timers in chat (GUI shows them live)',
        '//timer remove <n|name>      cancel (rm/del/stop; prefix match ok)',
        '//timer pause <n|name>       pause; resume <n|name> to continue',
        '//timer extend <n|name> 2m   add time (-30s subtracts)',
        '//timer snooze [5m]          re-run the last finished timer',
        '//timer clear                remove all timers',
        '//timer sound [name|off]     pick alert sound; sounds lists them, test previews',
        '//timer set <key> <value>    tweak: ' .. SET_KEYS,
        'Drag the title bar to move it; the minus button minimizes. Timers survive //lua reload and relog.',
    }
    for _, l in ipairs(lines) do
        windower.add_to_chat(207, chat_sanitize(l))
    end
end

local function handle_command(...)
    if slate.handle_command(...) then
        return
    end
    local args = {...}
    local sub = (args[1] or ''):lower()

    if sub == '' then
        if #timers > 0 then
            cmd_list()
        else
            msg('No timers. Try //timer 5m Tea - or //timer help.')
        end
        return
    end

    local action = SUBS[sub]

    if action == 'add' then
        cmd_add(args, 2, false)

    elseif action == 'repeat' then
        cmd_add(args, 2, true)

    elseif action == 'at' then
        cmd_at(args, 2)

    elseif action == 'list' then
        cmd_list()

    elseif action == 'remove' then
        local query = table.concat(args, ' ', 2)
        local t = resolve_or_complain(query, 'remove')
        if t then
            remove_timer_obj(t)
            msg('Removed: ' .. t.name .. '.')
        end

    elseif action == 'clear' then
        local n = #timers
        timers = {}
        finished = {}
        save_timers()
        msg(n == 0 and 'Nothing to clear.' or ('Cleared ' .. n .. ' timer(s).'))

    elseif action == 'pause' then
        local t = resolve_or_complain(table.concat(args, ' ', 2), 'pause')
        if t then
            if t.paused then
                msg(t.name .. ' is already paused.')
            else
                t.remaining = t.end_at - os.time()
                if t.remaining < 1 then t.remaining = 1 end
                t.paused = true
                save_timers()
                msg('Paused ' .. t.name .. ' at ' .. fmt_clock(t.remaining) .. '.')
            end
        end

    elseif action == 'resume' then
        local t = resolve_or_complain(table.concat(args, ' ', 2), 'resume')
        if t then
            if not t.paused then
                msg(t.name .. ' is not paused.')
            else
                t.end_at = os.time() + t.remaining
                t.remaining = nil
                t.paused = false
                save_timers()
                msg('Resumed ' .. t.name .. ' - rings at ' .. os.date('%H:%M:%S', t.end_at) .. '.')
            end
        end

    elseif action == 'extend' then
        -- find the longest duration parse anchored to the end of the args
        local secs, name_end = nil, nil
        for i = 2, #args do
            local s, consumed = parse_signed_duration(args, i)
            if s and i + consumed - 1 == #args then
                secs, name_end = s, i - 1
                break
            end
        end
        if not secs then
            msg('Usage: //timer extend <n|name> 2m  (or -30s to shorten)')
            return
        end
        local query = table.concat(args, ' ', 2, name_end)
        local t = resolve_or_complain(query, 'extend')
        if t then
            if t.paused then
                t.remaining = math.max(1, t.remaining + secs)
                msg(string.format('%s %s%s -> %s left (paused).', t.name, secs >= 0 and '+' or '-',
                    fmt_dur(math.abs(secs)), fmt_clock(t.remaining)))
            else
                t.end_at = t.end_at + secs
                local rem = math.max(0, t.end_at - os.time())
                msg(string.format('%s %s%s -> %s left.', t.name, secs >= 0 and '+' or '-',
                    fmt_dur(math.abs(secs)), fmt_clock(rem)))
            end
            save_timers()
        end

    elseif action == 'snooze' then
        if not last_done then
            msg('Nothing to snooze - no timer has finished yet.')
            return
        end
        local secs = parse_duration(args, 2)
        if not secs then
            secs = parse_duration({settings.snooze}, 1) or 300
        end
        for i = #finished, 1, -1 do
            if finished[i].name == last_done.name then table.remove(finished, i) end
        end
        local t = add_timer(secs, last_done.name)
        msg('Snoozed ' .. t.name .. ' for ' .. fmt_dur(secs) .. '.')

    elseif action == 'sound' then
        if args[2] then
            cmd_set('sound', table.concat(args, ' ', 2))
        else
            msg('Sound: ' .. settings.sound.name .. ' (x' .. settings.sound.repeats
                .. '). Available: ' .. table.concat(available_sounds(), ', ') .. ', off.')
        end

    elseif action == 'sounds' then
        msg('Available: ' .. table.concat(available_sounds(), ', ')
            .. '. Current: ' .. settings.sound.name .. '. Drop .wav files in addons/Chime/sounds/.')

    elseif action == 'test' then
        finished[#finished + 1] = {name = 'Test', until_clock = os.clock() + (tonumber(settings.linger) or 12)}
        play_alert()
        msg('This is what a finished timer looks and sounds like.')

    elseif action == 'set' then
        cmd_set(args[2], args[3] and table.concat(args, ' ', 3) or nil)

    elseif action == 'pos' then
        local x, y = tonumber(args[2]), tonumber(args[3])
        if x and y then
            settings.display.pos.x, settings.display.pos.y = x, y
            build_ui()
            ui.panel:pos(x, y)
            config.save(settings)
            msg(string.format('Moved to %d, %d.', x, y))
        else
            msg('Usage: //timer pos <x> <y> - or just drag the title bar.')
        end

    elseif action == 'save' then
        config.save(settings)
        save_timers()
        msg('Settings and timers saved.')

    elseif action == 'help' then
        cmd_help()

    else
        -- bare shortcut: //timer 5m Dinner
        local secs = parse_duration(args, 1)
        if secs then
            cmd_add(args, 1, false)
        else
            msg('Unknown command "' .. sub .. '". //timer help for usage.')
        end
    end
end

windower.register_event('addon command', handle_command)

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

windower.register_event('load', function()
    -- build the (hidden) panel up front so the dock taskbar lists chime
    build_ui()
    local player = windower.ffxi.get_player()
    if player and player.name then
        char_name = player.name
        restore_timers()
    end
end)

windower.register_event('login', function(name)
    char_name = name
    timers = {}
    finished = {}
    restore_timers()
end)

windower.register_event('logout', function()
    save_timers()
    timers = {}
    finished = {}
    char_name = nil
    if ui.built then
        ui.panel:hide()
    end
end)

windower.register_event('unload', function()
    save_timers()
    config.save(settings)
    if ui.built then
        ui.panel:hide()
    end
end)

-------------------------------------------------------------------------------
-- Test hooks (only active when loaded by the offline test harness)
-------------------------------------------------------------------------------

if _CHIME_TEST then
    _CHIME_TEST.parse_duration = parse_duration
    _CHIME_TEST.parse_signed_duration = parse_signed_duration
    _CHIME_TEST.parse_at = parse_at
    _CHIME_TEST.parse_clock = parse_clock
    _CHIME_TEST.parse_combo = parse_combo
    _CHIME_TEST.fmt_clock = fmt_clock
    _CHIME_TEST.fmt_dur = fmt_dur
    _CHIME_TEST.ulen = ulen
    _CHIME_TEST.usub = usub
    _CHIME_TEST.handle_command = handle_command
    _CHIME_TEST.tick = tick
    _CHIME_TEST.render = render
    _CHIME_TEST.timers = function() return timers end
    _CHIME_TEST.finished = function() return finished end
    _CHIME_TEST.settings = settings
    _CHIME_TEST.save_timers = save_timers
    _CHIME_TEST.restore_timers = restore_timers
    _CHIME_TEST.sorted_timers = sorted_timers
    _CHIME_TEST.find_timer = find_timer
end
