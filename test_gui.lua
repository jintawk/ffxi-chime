-- Offline smoke test for Chime's mythril port: drives the timer HUD render so
-- mythril.Bar (incl. the paused track_off_hl fill) and Panel/Label run for real.
-- Stubs windower/texts/images/config. Run with local Lua 5.1.

_addon = {name = 'Chime'}
_CHIME_TEST = {}

-- Windower extends coroutine with schedule(); stock Lua lacks it
coroutine.schedule = function() end

local events = {}
windower = {
    windower_path = 'C:/Program Files (x86)/Windower/',
    -- a nonexistent path: restore_timers finds no file (deterministic 0-start)
    -- and save_timers no-ops, so the test never touches the real data folder
    addon_path = 'C:/nonexistent-chime-harness/',
    register_event = function(name, fn) events[name] = fn end,
    add_to_chat = function() end,
    play_sound = function() end,
    create_dir = function() end,
    get_dir = function() return {} end,
    ffxi = {
        get_player = function() return {name = 'Test', status = 1} end,
    },
}

package.preload['texts'] = function()
    return {new = function(str)
        local t = {_str = str, _visible = false}
        function t:hide() self._visible = false end
        function t:show() self._visible = true end
        function t:visible(v) if v ~= nil then self._visible = v end return self._visible end
        function t:text(s) self._str = s end
        function t:pos() end
        function t:color() end
        function t:alpha() end
        function t:size() end
        function t:extents() return 40, 12 end
        function t:hover() return false end
        function t:destroy() end
        return t
    end}
end
package.preload['images'] = function()
    return {new = function(s)
        local t = {_visible = false, _alpha = s.color and s.color.alpha}
        function t:show() self._visible = true end
        function t:hide() self._visible = false end
        function t:visible(v) if v ~= nil then self._visible = v end return self._visible end
        function t:pos() end
        function t:size(w, h) self._w, self._h = w, h end
        function t:color() end
        function t:alpha(a) self._alpha = a end
        function t:repeat_xy() end
        function t:destroy() end
        return t
    end}
end
package.preload['config'] = function()
    return {
        load = function(defaults) return defaults end,
        save = function() end,
        register = function() end,
    }
end

package.path = 'C:/Program Files (x86)/Windower/addons/libs/?.lua;'
    .. 'C:/Program Files (x86)/Windower/addons/Chime/?.lua;' .. package.path

dofile('C:/Program Files (x86)/Windower/addons/Chime/Chime.lua')

local function check(cond, msg)
    if not cond then print('FAIL: ' .. msg) os.exit(1) end
end

-- load builds the (hidden) panel and tries to restore timers (no file -> noop)
events['load']()

-- add two timers and pause one, all via the real command handler
_CHIME_TEST.handle_command('5m', 'Tea')
_CHIME_TEST.handle_command('10s', 'Pull')
check(#_CHIME_TEST.timers() == 2, 'two timers added')
_CHIME_TEST.handle_command('pause', 'Tea')
local paused = 0
for _, t in ipairs(_CHIME_TEST.timers()) do if t.paused then paused = paused + 1 end end
check(paused == 1, 'one timer paused')

-- tick runs the timer logic + render: mythril.Bar set() for active AND paused
-- (paused uses mythril.color.track_off_hl) must not error
_CHIME_TEST.tick()

-- the finished-banner path (a flashing extras Label)
_CHIME_TEST.handle_command('test')
check(#_CHIME_TEST.finished() >= 1, 'test added a finished banner')
_CHIME_TEST.tick()

-- clear removes everything and re-renders cleanly
_CHIME_TEST.handle_command('clear')
check(#_CHIME_TEST.timers() == 0, 'clear removed all timers')
_CHIME_TEST.tick()

print('ALL OK')
