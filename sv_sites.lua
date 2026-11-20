--[[
    dps-cityworker - work sites

    Every place the job uses is captured in game: an admin stands on the spot
    and runs /cityspot <kind>. The server reads where they stand and keeps it
    in the city_work_sites table. Nothing is typed in by hand.

    Kinds: one per job type (pipe, pothole, ...), plus
      emergency - where an emergency can happen
      depot     - where the boss stands (one only)
      truck     - where the work truck comes out (one only)
]]

local Config = lib.require('config')
local Server = lib.require('sv_config')

Sites = {}

-- What an admin can type -> the kind that is stored
local KINDS = {
    pipe = 'pipe', pothole = 'pothole',
    meter = 'meter_reading', meter_reading = 'meter_reading',
    hydrant = 'hydrant', manhole = 'manhole',
    drain = 'storm_drain', storm_drain = 'storm_drain',
    electrical = 'electrical', transformer = 'transformer',
    bridge = 'bridge_inspection', bridge_inspection = 'bridge_inspection',
    utility = 'utility_locating', utility_locating = 'utility_locating',
    emergency = 'emergency', depot = 'depot', truck = 'truck',
}
local ONE_ONLY = { depot = true, truck = true }
local KIND_HELP = 'pipe, pothole, meter, hydrant, manhole, drain, electrical, transformer, bridge, utility, emergency, depot, truck'

local byKind = {}   -- kind -> { { id, kind, coords = vector3, heading, label }, ... }
local loaded = false

local function publishDepot()
    local d = Sites.depot()
    GlobalState.dpsCityDepot = { x = d.x, y = d.y, z = d.z, w = d.w }
end

local function addRow(row)
    local site = {
        id = row.id, kind = row.kind, label = row.label,
        coords = vector3(row.x + 0.0, row.y + 0.0, row.z + 0.0),
        heading = (row.heading or 0) + 0.0,
    }
    byKind[row.kind] = byKind[row.kind] or {}
    table.insert(byKind[row.kind], site)
    return site
end

local function load()
    local rows
    for _ = 1, 20 do
        local ok, res = pcall(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS `city_work_sites` (
                  `id` int(11) NOT NULL AUTO_INCREMENT,
                  `kind` varchar(30) NOT NULL,
                  `x` float NOT NULL,
                  `y` float NOT NULL,
                  `z` float NOT NULL,
                  `heading` float NOT NULL DEFAULT 0,
                  `label` varchar(60) DEFAULT NULL,
                  `added_by` varchar(60) DEFAULT NULL,
                  `created_at` timestamp DEFAULT CURRENT_TIMESTAMP,
                  PRIMARY KEY (`id`),
                  KEY `kind` (`kind`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            ]])
            return MySQL.query.await('SELECT id, kind, x, y, z, heading, label FROM city_work_sites ORDER BY id')
        end)
        if ok and res then rows = res break end
        Wait(1000)
    end

    byKind = {}
    for _, row in ipairs(rows or {}) do addRow(row) end
    loaded = true
    publishDepot()

    if not rows then
        print('[dps-cityworker] ^1Could not read city_work_sites. No work sites are loaded.^0')
    else
        print(('[dps-cityworker] ^2%d captured spots loaded^0'):format(#rows))
    end
end

CreateThread(load)

--- The depot: the captured one, else the one in config.lua.
function Sites.depot()
    local s = byKind.depot and byKind.depot[1]
    if s then return vec4(s.coords.x, s.coords.y, s.coords.z, s.heading) end
    return Config.BossCoords
end

--- Where the truck comes out: the captured one, else the one in sv_config.lua.
function Sites.truck()
    local s = byKind.truck and byKind.truck[1]
    if s then return vec4(s.coords.x, s.coords.y, s.coords.z, s.heading) end
    return Server.VehicleSpawn
end

function Sites.of(kind) return byKind[kind] or {} end
function Sites.loaded() return loaded end

-- =====================================
-- ADMIN: CAPTURE SPOTS IN GAME
-- =====================================

local function say(source, text, kind)
    if source == 0 then print('[dps-cityworker] ' .. text) return end
    Bridge.Notify(source, text, kind or 'inform')
end

lib.addCommand('cityspot', {
    help = 'Save the spot you are standing on for the city worker job (Admin)',
    params = {
        { name = 'kind', type = 'string', help = KIND_HELP },
        { name = 'label', type = 'longString', help = 'A name for the spot (optional)', optional = true },
    },
    restricted = 'group.admin',
}, function(source, args)
    if source == 0 then return print('[dps-cityworker] /cityspot is used in game, standing on the spot') end
    if not loaded then return say(source, 'The spots are still loading. Try again in a moment.', 'error') end

    local kind = KINDS[(args.kind or ''):lower()]
    if not kind then return say(source, 'Kinds: ' .. KIND_HELP, 'error') end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return end
    local pos = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    -- The boss stands on the ground, so the depot is kept at foot height.
    local z = kind == 'depot' and (pos.z - 1.0) or pos.z
    local label = args.label and args.label:sub(1, 60) or nil

    if ONE_ONLY[kind] then
        MySQL.query.await('DELETE FROM city_work_sites WHERE kind = ?', { kind })
        byKind[kind] = nil
    end

    local id = MySQL.insert.await(
        'INSERT INTO city_work_sites (kind, x, y, z, heading, label, added_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { kind, pos.x, pos.y, z, heading, label, Bridge.GetIdentifier(source) })
    if not id then return say(source, 'The spot could not be saved', 'error') end

    addRow({ id = id, kind = kind, x = pos.x, y = pos.y, z = z, heading = heading, label = label })
    if kind == 'depot' then publishDepot() end

    say(source, ('Saved: %s (%d of this kind now)'):format(kind, #byKind[kind]), 'success')
end)

lib.addCommand('cityspots', {
    help = 'Count the saved city worker spots, and show the nearest one (Admin)',
    restricted = 'group.admin',
}, function(source)
    local parts = {}
    for kind, list in pairs(byKind) do parts[#parts + 1] = ('%s %d'):format(kind, #list) end
    table.sort(parts)
    say(source, #parts > 0 and table.concat(parts, ', ') or 'No spots saved yet')

    if source == 0 then return end
    local pos = GetEntityCoords(GetPlayerPed(source))
    local best, bestDist
    for _, list in pairs(byKind) do
        for _, s in ipairs(list) do
            local d = #(pos - s.coords)
            if not bestDist or d < bestDist then best, bestDist = s, d end
        end
    end
    if best then
        say(source, ('Nearest: %s%s, %.0f m away'):format(best.kind, best.label and (' "' .. best.label .. '"') or '', bestDist))
    end
end)

lib.addCommand('cityspotdel', {
    help = 'Delete the saved city worker spot nearest to you, within 15 m (Admin)',
    restricted = 'group.admin',
}, function(source)
    if source == 0 then return end
    local pos = GetEntityCoords(GetPlayerPed(source))
    local bestKind, bestIndex, bestDist
    for kind, list in pairs(byKind) do
        for i, s in ipairs(list) do
            local d = #(pos - s.coords)
            if d <= 15.0 and (not bestDist or d < bestDist) then bestKind, bestIndex, bestDist = kind, i, d end
        end
    end
    if not bestKind then return say(source, 'No saved spot within 15 m', 'error') end

    local site = table.remove(byKind[bestKind], bestIndex)
    MySQL.query.await('DELETE FROM city_work_sites WHERE id = ?', { site.id })
    if bestKind == 'depot' then publishDepot() end
    say(source, ('Deleted: %s (%.0f m away)'):format(bestKind, bestDist), 'success')
end)
