local Config = lib.require('config')
local isHired, activeJob = false, false
local cityBoss, startZone, currZone, currentCone
local JobBlip = nil
local CurrentTask = nil
local ControlRoomOpen = false
local Working = false        -- true while a repair is being done, so it cannot be started twice
local TrafficBegun = nil     -- id of the traffic control job the server has been told about

-- =====================================
-- BLIP SETUP
-- =====================================

local CITY_BLIP = AddBlipForCoord(Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z)
SetBlipSprite(CITY_BLIP, 566)
SetBlipDisplay(CITY_BLIP, 4)
SetBlipScale(CITY_BLIP, 0.8)
SetBlipAsShortRange(CITY_BLIP, true)
SetBlipColour(CITY_BLIP, 5)
BeginTextCommandSetBlipName("STRING")
AddTextComponentSubstringPlayerName("City Worker Job")
EndTextCommandSetBlipName(CITY_BLIP)

-- =====================================
-- TARGET HELPERS
-- =====================================

local function AddTargetEntity(entity, options)
    if GetResourceState('ox_target') == 'started' then
        local oxOptions = {}
        for _, opt in ipairs(options) do
            table.insert(oxOptions, {
                icon = opt.icon,
                label = opt.label,
                onSelect = opt.action,
                canInteract = opt.canInteract,
                distance = opt.distance or 2.0
            })
        end
        exports.ox_target:addLocalEntity(entity, oxOptions)
    else
        exports['qb-target']:AddTargetEntity(entity, { options = options, distance = 2.0 })
    end
end

local function RemoveTargetEntity(entity, labels)
    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeLocalEntity(entity, labels)
    else
        exports['qb-target']:RemoveTargetEntity(entity, labels)
    end
end

local function AddTargetZone(name, data, options)
    if GetResourceState('ox_target') == 'started' then
        local oxOptions = {}
        for _, opt in ipairs(options) do
            table.insert(oxOptions, {
                icon = opt.icon,
                label = opt.label,
                onSelect = opt.action,
                canInteract = opt.canInteract,
            })
        end
        return exports.ox_target:addSphereZone({
            name = name,
            coords = data.coords,
            radius = data.radius or 1.5,
            options = oxOptions,
        })
    else
        return exports['qb-target']:AddCircleZone(name, data.coords, data.radius or 1.5, {
            name = name,
            useZ = true,
        }, { options = options, distance = 2.0 })
    end
end

local function RemoveTargetZone(zone)
    if GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeZone(zone)
    else
        exports['qb-target']:RemoveZone(zone)
    end
end

-- =====================================
-- FORWARD DECLARATIONS
-- =====================================

local StopAllParticles -- Forward declaration for particle cleanup

-- =====================================
-- CLEANUP
-- =====================================

local function cleanupJob()
    -- Stop any active particle effects
    if StopAllParticles then StopAllParticles() end

    if currZone then
        RemoveTargetZone(currZone)
        currZone = nil
    end
    if DoesEntityExist(currentCone) then
        DeleteEntity(currentCone)
        currentCone = nil
    end
    if JobBlip then
        RemoveBlip(JobBlip)
        JobBlip = nil
    end
    CurrentTask = nil
end

local function resetJob()
    cleanupJob()
    isHired = false
    activeJob = false

    if DoesEntityExist(cityBoss) then
        RemoveTargetEntity(cityBoss, {'Start Work', 'Replace Work Truck', 'Job Menu', 'Finish Work'})
        DeleteEntity(cityBoss)
        cityBoss = nil
    end
    -- Note: Don't remove startZone here - it's created once at script load
    -- and should persist through character switches
end

-- =====================================
-- TASK PROPS & ANIMATIONS
-- =====================================

local function GetTaskProp(taskType)
    if Config.TaskProps and Config.TaskProps[taskType] then
        return Config.TaskProps[taskType]
    end
    return 'prop_roadcone02a' -- Default fallback
end

local function GetTaskAnimation(category)
    if Config.TaskAnimations and Config.TaskAnimations[category] then
        return Config.TaskAnimations[category]
    end
    return { dict = 'amb@world_human_welding@male@base', anim = 'base' }
end

local function SpawnTaskProp(taskType, coords)
    local propModel = GetTaskProp(taskType)
    lib.requestModel(propModel)

    local prop = CreateObject(propModel, coords.x, coords.y, coords.z - 1.0, false, false, false)
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)

    return prop
end

-- Task duration based on difficulty
local TaskDurations = {
    easy = 6000,
    medium = 8000,
    hard = 12000,
}

-- =====================================
-- PARTICLE EFFECTS SYSTEM
-- =====================================

local ActiveParticles = {}

-- Particle definitions for task types
local TaskParticles = {
    pipe = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 2.0,
        offset = vec3(0, 0, 0.5),
    },
    water_main = {
        dict = 'core',
        name = 'exp_grd_water',
        scale = 3.0,
        offset = vec3(0, 0, 0.3),
    },
    gas_leak = {
        dict = 'core',
        name = 'exp_grd_smoke',
        scale = 2.0,
        offset = vec3(0, 0, 0.5),
    },
    downed_lines = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 1.5,
        offset = vec3(0, 0, 1.0),
    },
    electrical = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 0.8,
        offset = vec3(0, 0, 0.5),
    },
    transformer = {
        dict = 'core',
        name = 'exp_grd_sparks',
        scale = 1.2,
        offset = vec3(0, 0, 1.5),
    },
    hydrant = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 1.0,
        offset = vec3(0, 0, 0.8),
    },
    storm_drain = {
        dict = 'core',
        name = 'water_splash_plane',
        scale = 0.8,
        offset = vec3(0, 0, -0.5),
    },
    hazmat = {
        dict = 'core',
        name = 'exp_grd_grenade_smoke',
        scale = 1.5,
        offset = vec3(0, 0, 0.3),
    },
}

local function StartTaskParticles(taskType, coords)
    local particleData = TaskParticles[taskType]
    if not particleData then return nil end

    -- Request particle asset
    RequestNamedPtfxAsset(particleData.dict)
    while not HasNamedPtfxAssetLoaded(particleData.dict) do
        Wait(10)
    end

    UseParticleFxAsset(particleData.dict)

    local particleCoords = coords + particleData.offset

    -- Start looped particle effect
    local particle = StartParticleFxLoopedAtCoord(
        particleData.name,
        particleCoords.x, particleCoords.y, particleCoords.z,
        0.0, 0.0, 0.0,
        particleData.scale,
        false, false, false, false
    )

    ActiveParticles[taskType] = particle
    return particle
end

local function StopTaskParticles(taskType)
    if ActiveParticles[taskType] then
        StopParticleFxLooped(ActiveParticles[taskType], false)
        ActiveParticles[taskType] = nil
    end
end

StopAllParticles = function()
    for taskType, particle in pairs(ActiveParticles) do
        if DoesParticleFxLoopedExist(particle) then
            StopParticleFxLooped(particle, false)
        end
    end
    ActiveParticles = {}
end

-- =====================================
-- SKILL CHECKS
-- =====================================

local function GetDifficultyForTask(taskType)
    local difficulties = {
        pipe = { 'easy', 'easy' },
        pothole = { 'easy' },
        streetlight = { 'easy', 'medium' },
        electrical = { 'medium', 'medium' },
        transformer = { 'medium', 'hard' },
        hazmat = { 'hard', 'hard' },
    }
    return difficulties[taskType] or Config.SkillCheck.Difficulty
end

local function DoTaskSkillCheck(taskType)
    local difficulty = GetDifficultyForTask(taskType)

    local success = lib.skillCheck(difficulty, Config.SkillCheck.Input)

    return success
end

-- =====================================
-- NEXT TASK
-- =====================================

function NextDelivery(data)
    if not data or not data.location then
        Bridge.Notify('No tasks available', 'error')
        return
    end

    activeJob = true
    CurrentTask = data

    -- Create blip for task location
    if JobBlip then RemoveBlip(JobBlip) end
    JobBlip = AddBlipForCoord(data.location.x, data.location.y, data.location.z)
    SetBlipSprite(JobBlip, 566)
    SetBlipColour(JobBlip, 5)
    SetBlipRoute(JobBlip, true)
    SetBlipRouteColour(JobBlip, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(data.taskType and ('Task: ' .. (data.label or data.taskType)) or 'Work Site')
    EndTextCommandSetBlipName(JobBlip)

    -- Stop any existing particles
    StopAllParticles()

    -- Spawn task prop
    if currentCone then DeleteEntity(currentCone) end
    currentCone = SpawnTaskProp(data.taskType or 'pipe', data.location)

    -- Start particle effects for applicable tasks
    StartTaskParticles(data.taskType, data.location)

    -- Create target zone for task
    if currZone then RemoveTargetZone(currZone) end

    local taskType = data.taskType or 'pipe'
    local targetOptions = {}

    -- Special handling for traffic control task
    if taskType == 'traffic_control' then
        targetOptions = {
            {
                icon = 'fas fa-road',
                label = 'Setup Traffic Control',
                action = function()
                    OpenTrafficControlMenu()
                end,
                canInteract = function()
                    return activeJob and isHired
                end,
            }
        }
    else
        -- Standard repair task
        targetOptions = {
            {
                icon = 'fas fa-wrench',
                label = data.label or 'Repair',
                action = function()
                    DoRepairTask()
                end,
                canInteract = function()
                    return activeJob and isHired
                end,
            }
        }
    end

    currZone = AddTargetZone('cityworker_task_' .. math.random(1000, 9999), {
        coords = data.location,
        radius = 2.0,
    }, targetOptions)

    local taskLabel = data.label or 'Repair Task'
    Bridge.Notify('New task: ' .. taskLabel, 'inform')
end

local function finishTask(result, doneText)
    if currZone then
        RemoveTargetZone(currZone)
        currZone = nil
    end
    if currentCone then
        DeleteEntity(currentCone)
        currentCone = nil
    end
    if JobBlip then
        RemoveBlip(JobBlip)
        JobBlip = nil
    end
    StopAllParticles()
    CurrentTask = nil
    activeJob = false

    local text = (doneText .. ' +$%d | +%d XP'):format(result.payment, result.xp)
    if (result.travelPay or 0) > 0 then text = text .. (' (driving money $%d)'):format(result.travelPay) end
    Bridge.Notify(text, 'success')
    if result.sectorId then
        Bridge.Notify(('%s is now at %.0f%%'):format(result.sectorLabel or result.sectorId, result.sectorHealth), 'inform')
    end

    Wait(5000)
    if isHired and result.nextTask then NextDelivery(result.nextTask) end
end

function DoRepairTask()
    if not activeJob or not CurrentTask or Working then return end
    Working = true
    local ok, err = pcall(DoRepairTaskInner)
    Working = false
    if not ok then print('[dps-cityworker] repair failed: ' .. tostring(err)) end
end

function DoRepairTaskInner()
    -- The server checks you are at the site with your truck, and starts the clock
    local began, info = lib.callback.await('dps-cityworker:server:BeginTask', false, CurrentTask.id)
    if not began then
        Bridge.Notify(info or 'You cannot start this job yet', 'error')
        return
    end

    local taskType = CurrentTask.taskType or 'pipe'
    local category = CurrentTask.category or 'maintenance'
    local difficulty = CurrentTask.difficulty or 'easy'

    -- Get category-specific animation
    local animData = GetTaskAnimation(category)
    lib.requestAnimDict(animData.dict)
    TaskPlayAnim(cache.ped, animData.dict, animData.anim, 8.0, -8.0, -1, 1, 0, false, false, false)

    -- How long the work takes comes from the server (it will not pay sooner)
    local duration = (tonumber(info) and info * 1000) or TaskDurations[difficulty] or 8000

    -- Task-specific labels
    local taskLabels = {
        pipe = 'Repairing pipe...',
        pothole = 'Filling pothole...',
        meter_reading = 'Reading meter...',
        graffiti = 'Removing graffiti...',
        trash = 'Collecting trash...',
        streetlight = 'Fixing streetlight...',
        hydrant = 'Inspecting hydrant...',
        sign_repair = 'Repairing sign...',
        manhole = 'Inspecting manhole...',
        storm_drain = 'Clearing drain...',
        electrical = 'Repairing electrical box...',
        traffic_control = 'Setting up traffic control...',
        tree_trimming = 'Trimming tree...',
        cable_install = 'Installing cable...',
        transformer = 'Servicing transformer...',
        hazmat = 'Cleaning hazmat...',
        bridge_inspection = 'Inspecting bridge...',
        utility_locating = 'Locating utilities...',
        water_main = 'Fixing water main!',
        gas_leak = 'Sealing gas leak!',
        downed_lines = 'Securing power lines!',
        fallen_tree = 'Removing fallen tree!',
    }

    local progressLabel = taskLabels[taskType] or CurrentTask.label or 'Working...'

    local success = lib.progressBar({
        duration = duration,
        label = progressLabel,
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = animData.dict, clip = animData.anim },
    })

    ClearPedTasks(cache.ped)

    if not success then
        Bridge.Notify('Task cancelled', 'error')
        return
    end

    -- Skill check
    local passed = DoTaskSkillCheck(taskType)

    if not passed then
        Bridge.Notify('Task failed - try again!', 'error')
        return
    end

    local paymentSuccess, result = lib.callback.await('dps-cityworker:server:Payment', false, CurrentTask.id)

    if paymentSuccess and result then
        finishTask(result, 'Job done!')
    else
        Bridge.Notify('The city could not sign this job off. Stay at the site and try again.', 'error')
    end
end

-- =====================================
-- WORK START/FINISH
-- =====================================

local function startWork(netid, data)
    local workVehicle = lib.waitFor(function()
        if NetworkDoesEntityExistWithNetworkId(netid) then
            return NetToVeh(netid)
        end
    end, 'Could not load entity in time.', 3000)

    if not workVehicle then
        Bridge.Notify('Failed to spawn work vehicle', 'error')
        return
    end

    -- The plate and the keys are set by the server
    SetVehicleColours(workVehicle, 111, 111)
    SetVehicleDirtLevel(workVehicle, 1)
    if GetResourceState('wasabi_carlock') ~= 'started' then handleVehicleKeys(workVehicle) end
    SetVehicleEngineOn(workVehicle, true, true)
    Bridge.SetVehicleFuel(workVehicle, 100.0)

    if not data then return end   -- a replacement truck: the shift is already running

    isHired = true
    Bridge.Notify('You started your shift. /citywork opens your job menu.', 'success')
    NextDelivery(data)
    ShowActiveEmergencies()
end

local function finishWork()
    local ped = cache.ped
    local pos = GetEntityCoords(ped)
    local finishspot = vec3(Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z)

    if #(pos - finishspot) > 15.0 then
        Bridge.Notify('Return to HQ to clock out', 'error')
        return
    end

    if not isHired then return end

    local success = lib.callback.await('dps-cityworker:server:clockOut', false)
    if success then
        Bridge.Notify('You ended your shift', 'success')
        cleanupJob()
        isHired = false
        activeJob = false
    end
end

-- =====================================
-- BOSS PED
-- =====================================

local function yeetPed()
    if DoesEntityExist(cityBoss) then
        RemoveTargetEntity(cityBoss, {'Start Work', 'Replace Work Truck', 'Job Menu', 'Finish Work'})
        DeleteEntity(cityBoss)
        cityBoss = nil
    end
end

local function spawnPed()
    if DoesEntityExist(cityBoss) then return end

    lib.requestModel(Config.BossModel)
    cityBoss = CreatePed(0, Config.BossModel, Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z, Config.BossCoords.w, false, false)
    SetEntityAsMissionEntity(cityBoss, true, true)
    SetPedFleeAttributes(cityBoss, 0, 0)
    SetBlockingOfNonTemporaryEvents(cityBoss, true)
    SetEntityInvincible(cityBoss, true)
    FreezeEntityPosition(cityBoss, true)
    TaskStartScenarioInPlace(cityBoss, 'WORLD_HUMAN_CLIPBOARD', 0, true)

    AddTargetEntity(cityBoss, {
        {
            icon = 'fas fa-hard-hat',
            label = 'Start Work',
            action = function()
                local netid, data = lib.callback.await('dps-cityworker:server:spawnVehicle', false)
                if netid then
                    startWork(netid, data)
                else
                    Bridge.Notify(data or 'Could not start work', 'error')
                end
            end,
            canInteract = function()
                return not isHired
            end,
        },
        {
            icon = 'fas fa-truck-pickup',
            label = 'Replace Work Truck',
            action = function()
                local netid, why = lib.callback.await('dps-cityworker:server:newTruck', false)
                if netid then
                    startWork(netid, nil)
                    Bridge.Notify('Here is another truck. Look after this one.', 'success')
                else
                    Bridge.Notify(why or 'No truck available', 'error')
                end
            end,
            canInteract = function()
                return isHired
            end,
        },
        {
            icon = 'fas fa-clipboard-list',
            label = 'Job Menu',
            action = function()
                OpenWorkMenu()
            end,
            canInteract = function()
                return isHired
            end,
        },
        {
            icon = 'fas fa-sign-out-alt',
            label = 'Finish Work',
            action = function()
                finishWork()
            end,
            canInteract = function()
                return isHired
            end,
        },
    })
end

-- =====================================
-- SPAWN ZONE
-- =====================================

startZone = lib.points.new({
    coords = vec3(Config.BossCoords.x, Config.BossCoords.y, Config.BossCoords.z),
    distance = 50,
})

function startZone:onEnter()
    spawnPed()
end

function startZone:onExit()
    yeetPed()
end

-- =====================================
-- CONTROL ROOM NUI
-- =====================================

RegisterNetEvent('dps-cityworker:client:OpenControlRoom', function()
    local canOpen, sectorData = lib.callback.await('dps-cityworker:server:OpenControlRoom', false)

    if not canOpen then return end

    ControlRoomOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        sectors = sectorData
    })
end)

RegisterNetEvent('dps-cityworker:client:UpdateSectorHealth', function(sectorHealth)
    if ControlRoomOpen then
        local data = {}
        for id, health in pairs(sectorHealth) do
            data[id] = {
                health = health,
                label = Config.Sectors[id] and Config.Sectors[id].label or id,
            }
        end
        SendNUIMessage({
            action = 'update',
            sectors = data
        })
    end
end)

RegisterNUICallback('closeUI', function(_, cb)
    ControlRoomOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    cb('ok')
end)

RegisterNUICallback('dispatchCrew', function(data, cb)
    local success, msg = lib.callback.await('dps-cityworker:server:DispatchCrew', false, data.sector)
    if success then
        Bridge.Notify('Crew dispatched to ' .. data.sector, 'success')
    else
        Bridge.Notify(msg or 'Failed to dispatch', 'error')
    end
    cb('ok')
end)

-- =====================================
-- BLACKOUT EFFECTS
-- =====================================

-- Which sectors are dark is kept by the server in GlobalState.dpsCityBlackouts.
-- Everyone reads the same list, so a repair turns the lights back on for all
-- and a player who joins later sees the blackout too.
local BlackoutActive = {}
local blackoutThread = false

local function insideDarkSector()
    local pos = GetEntityCoords(cache.ped)
    for sectorId in pairs(BlackoutActive) do
        local sector = Config.Sectors[sectorId]
        if sector and #(pos - sector.coords) < sector.radius then return true end
    end
    return false
end

local function runBlackouts()
    if blackoutThread then return end
    blackoutThread = true
    CreateThread(function()
        SetArtificialLightsStateAffectsVehicles(false)   -- headlights keep working
        while next(BlackoutActive) do
            if insideDarkSector() then
                SetArtificialLightsState(true)
                Wait(math.random(100, 500))
                SetArtificialLightsState(false)
                Wait(math.random(500, 2000))
            else
                Wait(1000)
            end
        end
        SetArtificialLightsState(false)
        blackoutThread = false
    end)
end

local function applyBlackouts(list)
    list = type(list) == 'table' and list or {}
    for sectorId in pairs(list) do
        local sector = Config.Sectors[sectorId]
        if sector and not BlackoutActive[sectorId] and (isHired or #(GetEntityCoords(cache.ped) - sector.coords) < sector.radius) then
            Bridge.Notify(('ALERT: %s has lost power!'):format(sector.label), 'error')
        end
    end
    for sectorId in pairs(BlackoutActive) do
        local sector = Config.Sectors[sectorId]
        if sector and not list[sectorId] and isHired then
            Bridge.Notify(('%s has power again'):format(sector.label), 'success')
        end
    end
    BlackoutActive = list
    if next(BlackoutActive) then runBlackouts() end
end

AddStateBagChangeHandler('dpsCityBlackouts', 'global', function(_, _, value)
    applyBlackouts(value)
end)

CreateThread(function()
    Wait(3000)
    applyBlackouts(GlobalState.dpsCityBlackouts)
end)

-- =====================================
-- EMERGENCY EVENTS
-- =====================================

local ActiveEmergencyBlips = {}
local EmergencyProps = {}
local EmergencyProximityPoints = {} -- Proximity points that auto-create zones
local EmergencyZoneCreated = {}     -- Track which sectors already have zones spawned
local EmergencyZones = {}           -- sector -> target zone, so it can be removed again

local function showEmergency(data, quiet)
    -- Create emergency blip
    if ActiveEmergencyBlips[data.sector] then
        RemoveBlip(ActiveEmergencyBlips[data.sector])
    end

    local blip = AddBlipForCoord(data.coords.x, data.coords.y, data.coords.z)
    SetBlipSprite(blip, 126) -- Warning icon
    SetBlipColour(blip, 1) -- Red
    SetBlipScale(blip, 1.2)
    SetBlipFlashes(blip, true)
    SetBlipAsShortRange(blip, false) -- Always visible
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentSubstringPlayerName(('EMERGENCY: %s'):format(data.label))
    EndTextCommandSetBlipName(blip)

    ActiveEmergencyBlips[data.sector] = blip

    -- Alert notification with sound
    PlaySoundFrontend(-1, "TIMER_STOP", "HUD_MINI_GAME_SOUNDSET", true)

    -- Set up proximity point so the zone auto-creates when the player arrives
    -- This ensures props/particles/target appear even if the dialog is missed
    EmergencyZoneCreated[data.sector] = false

    -- Remove any previous proximity point for this sector
    if EmergencyProximityPoints[data.sector] then
        EmergencyProximityPoints[data.sector]:remove()
        EmergencyProximityPoints[data.sector] = nil
    end

    local emergencyData = data -- capture for closure
    local point = lib.points.new({
        coords = vec3(data.coords.x, data.coords.y, data.coords.z),
        distance = 80,
    })

    function point:onEnter()
        if isHired and not EmergencyZoneCreated[emergencyData.sector] then
            EmergencyZoneCreated[emergencyData.sector] = true
            CreateEmergencyZone(emergencyData)
        end
    end

    EmergencyProximityPoints[data.sector] = point
    if quiet then return end

    -- Only show detailed alert to on-duty workers
    if isHired then
        lib.notify({
            title = 'EMERGENCY ALERT',
            description = ('%s at %s!\nBonus XP: +%d'):format(data.label, data.sectorLabel, data.xpBonus),
            type = 'error',
            duration = 15000,
            icon = 'fa-solid fa-triangle-exclamation',
        })

        -- Offer to respond
        local response = lib.alertDialog({
            header = 'Emergency Response',
            content = ('**%s** reported at **%s**!\n\nThis is a high-priority emergency. Respond for bonus pay and XP.\n\nSet GPS to emergency location?'):format(data.label, data.sectorLabel),
            centered = true,
            cancel = true,
            labels = { confirm = 'Respond', cancel = 'Ignore' }
        })

        if response == 'confirm' then
            SetNewWaypoint(data.coords.x, data.coords.y)
            Bridge.Notify('GPS set to emergency. Hurry!', 'warning')

            -- Immediately create the zone if not already done by proximity
            if not EmergencyZoneCreated[data.sector] then
                EmergencyZoneCreated[data.sector] = true
                CreateEmergencyZone(data)
            end
        end
    else
        -- Non-workers just see the notification
        lib.notify({
            title = 'City Alert',
            description = ('%s reported at %s'):format(data.label, data.sectorLabel),
            type = 'warning',
            duration = 8000,
        })
    end
end

RegisterNetEvent('dps-cityworker:client:EmergencyAlert', function(data)
    showEmergency(data, false)
end)

--- Emergencies that were already running when this worker clocked in.
function ShowActiveEmergencies()
    local list = lib.callback.await('dps-cityworker:server:GetActiveEmergencies', false) or {}
    for sectorId, em in pairs(list) do
        if not ActiveEmergencyBlips[sectorId] then
            showEmergency({
                sector = sectorId, type = em.type, label = em.label,
                sectorLabel = em.sectorLabel, coords = em.coords, xpBonus = 0,
            }, true)
            Bridge.Notify(('Emergency in progress: %s at %s'):format(em.label, em.sectorLabel), 'warning')
        end
    end
end

function CreateEmergencyZone(data)
    -- Snap coords to actual ground level as a safety net
    local groundZ = data.coords.z
    local found, z = GetGroundZFor_3dCoord(data.coords.x, data.coords.y, data.coords.z + 50.0, false)
    if found then
        groundZ = z
    end
    local groundCoords = vec3(data.coords.x, data.coords.y, groundZ)

    -- Spawn emergency prop at ground-corrected position
    local propModel = GetTaskProp(data.type)
    lib.requestModel(propModel)
    local prop = CreateObject(propModel, groundCoords.x, groundCoords.y, groundCoords.z - 1.0, false, false, false)
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)
    EmergencyProps[data.sector] = prop

    -- Start emergency particle effects at ground level
    StartTaskParticles(data.type, groundCoords)

    -- Create target zone at ground-corrected position
    local zoneName = 'emergency_' .. data.sector
    if EmergencyZones[data.sector] then RemoveTargetZone(EmergencyZones[data.sector]) end
    EmergencyZones[data.sector] = AddTargetZone(zoneName, {
        coords = groundCoords,
        radius = 3.0,
    }, {
        {
            icon = 'fas fa-exclamation-triangle',
            label = ('Respond: %s'):format(data.label),
            action = function()
                RespondToEmergency(data.sector)
            end,
            canInteract = function()
                return isHired
            end,
        }
    })
end

function RespondToEmergency(sectorId)
    local canRespond, emergencyData = lib.callback.await('dps-cityworker:server:RespondToEmergency', false, sectorId)

    if not canRespond then
        Bridge.Notify(emergencyData or 'Cannot respond to emergency', 'error')
        return
    end

    -- Emergency repair with higher stakes
    local animData = GetTaskAnimation('emergency')
    lib.requestAnimDict(animData.dict)

    local success = lib.progressBar({
        duration = (emergencyData.seconds or 15) * 1000, -- Emergencies take longer
        label = ('EMERGENCY: %s'):format(emergencyData.label),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = { dict = animData.dict, clip = animData.anim },
    })

    ClearPedTasks(cache.ped)

    if not success then
        Bridge.Notify('Emergency response cancelled!', 'error')
        return
    end

    -- Harder skill check for emergencies
    local passed = lib.skillCheck({'medium', 'hard', 'hard'}, Config.SkillCheck.Input)

    if not passed then
        Bridge.Notify('Emergency repair failed! Try again!', 'error')
        return
    end

    -- Complete the emergency
    local completed = lib.callback.await('dps-cityworker:server:CompleteEmergency', false, sectorId)

    if completed then
        Bridge.Notify('Emergency resolved! Great work!', 'success')

        -- Stop particle effects
        StopAllParticles()

        -- Clean up emergency prop
        if EmergencyProps[sectorId] then
            DeleteEntity(EmergencyProps[sectorId])
            EmergencyProps[sectorId] = nil
        end
    end
end

RegisterNetEvent('dps-cityworker:client:EmergencyResolved', function(sectorId)
    -- Remove emergency blip
    if ActiveEmergencyBlips[sectorId] then
        RemoveBlip(ActiveEmergencyBlips[sectorId])
        ActiveEmergencyBlips[sectorId] = nil
    end

    -- Remove proximity point
    if EmergencyProximityPoints[sectorId] then
        EmergencyProximityPoints[sectorId]:remove()
        EmergencyProximityPoints[sectorId] = nil
    end
    EmergencyZoneCreated[sectorId] = nil
    if EmergencyZones[sectorId] then
        RemoveTargetZone(EmergencyZones[sectorId])
        EmergencyZones[sectorId] = nil
    end

    -- Stop particle effects
    if StopAllParticles then StopAllParticles() end

    -- Clean up prop
    if EmergencyProps[sectorId] then
        DeleteEntity(EmergencyProps[sectorId])
        EmergencyProps[sectorId] = nil
    end

    local sector = Config.Sectors[sectorId]
    if sector then
        lib.notify({
            title = 'Emergency Resolved',
            description = ('%s emergency has been handled'):format(sector.label),
            type = 'success',
            duration = 5000,
        })
    end
end)

-- =====================================
-- TRAFFIC CONTROL SYSTEM
-- =====================================

local PlacedTrafficProps = {}
local MAX_TRAFFIC_PROPS = 8

local function PlaceTrafficProp(propType)
    if #PlacedTrafficProps >= MAX_TRAFFIC_PROPS then
        Bridge.Notify('Maximum props placed (8)', 'error')
        return
    end

    local propModel = Config.TrafficProps[propType]
    if not propModel then return end

    lib.requestModel(propModel)

    local playerPos = GetEntityCoords(cache.ped)
    local playerHeading = GetEntityHeading(cache.ped)
    local forward = GetEntityForwardVector(cache.ped)

    -- Place prop 1.5m in front of player
    local placePos = playerPos + forward * 1.5

    -- Animation for placing
    lib.requestAnimDict('anim@heists@narcotics@trash')
    TaskPlayAnim(cache.ped, 'anim@heists@narcotics@trash', 'drop_front', 8.0, -8.0, 1000, 0, 0, false, false, false)

    Wait(500)

    local prop = CreateObject(propModel, placePos.x, placePos.y, placePos.z - 1.0, false, false, false)
    PlaceObjectOnGroundProperly(prop)
    FreezeEntityPosition(prop, true)
    SetEntityHeading(prop, playerHeading)

    table.insert(PlacedTrafficProps, prop)

    ClearPedTasks(cache.ped)
    Bridge.Notify(('Placed %s (%d/%d)'):format(propType, #PlacedTrafficProps, MAX_TRAFFIC_PROPS), 'success')
end

local function PickupTrafficProp()
    local playerPos = GetEntityCoords(cache.ped)
    local closestProp = nil
    local closestDist = 3.0

    for i, prop in ipairs(PlacedTrafficProps) do
        if DoesEntityExist(prop) then
            local propPos = GetEntityCoords(prop)
            local dist = #(playerPos - propPos)
            if dist < closestDist then
                closestDist = dist
                closestProp = i
            end
        end
    end

    if closestProp then
        lib.requestAnimDict('anim@heists@narcotics@trash')
        TaskPlayAnim(cache.ped, 'anim@heists@narcotics@trash', 'pickup', 8.0, -8.0, 1000, 0, 0, false, false, false)

        Wait(500)

        DeleteEntity(PlacedTrafficProps[closestProp])
        table.remove(PlacedTrafficProps, closestProp)

        ClearPedTasks(cache.ped)
        Bridge.Notify(('Picked up prop (%d remaining)'):format(#PlacedTrafficProps), 'inform')
    else
        Bridge.Notify('No props nearby', 'error')
    end
end

local function ClearAllTrafficProps()
    for _, prop in ipairs(PlacedTrafficProps) do
        if DoesEntityExist(prop) then
            DeleteEntity(prop)
        end
    end
    PlacedTrafficProps = {}
end

-- Traffic control radial menu (when doing traffic_control task)
local TrafficControlActive = false

function OpenTrafficControlMenu()  -- forward-declared below the file header
    if TrafficControlActive or not CurrentTask then return end

    -- Tell the server the work has started (once per job)
    if TrafficBegun ~= CurrentTask.id then
        local began, why = lib.callback.await('dps-cityworker:server:BeginTask', false, CurrentTask.id)
        if not began then
            Bridge.Notify(why or 'You cannot start this job yet', 'error')
            return
        end
        TrafficBegun = CurrentTask.id
    end
    TrafficControlActive = true

    lib.registerContext({
        id = 'traffic_control_menu',
        title = 'Traffic Control Equipment',
        options = {
            {
                title = 'Place Cone',
                description = 'Place a traffic cone',
                icon = 'fa-solid fa-cone-striped',
                onSelect = function()
                    PlaceTrafficProp('Cone')
                end,
            },
            {
                title = 'Place Barrier',
                description = 'Place a road barrier',
                icon = 'fa-solid fa-road-barrier',
                onSelect = function()
                    PlaceTrafficProp('Barrier')
                end,
            },
            {
                title = 'Place Stop Sign',
                description = 'Place a stop sign',
                icon = 'fa-solid fa-octagon',
                onSelect = function()
                    PlaceTrafficProp('Sign_Stop')
                end,
            },
            {
                title = 'Place Slow Sign',
                description = 'Place a slow sign',
                icon = 'fa-solid fa-diamond',
                onSelect = function()
                    PlaceTrafficProp('Sign_Slow')
                end,
            },
            {
                title = 'Place Work Light',
                description = 'Place a work light',
                icon = 'fa-solid fa-lightbulb',
                onSelect = function()
                    PlaceTrafficProp('Light')
                end,
            },
            {
                title = 'Pickup Nearest',
                description = 'Pick up nearest prop',
                icon = 'fa-solid fa-hand',
                onSelect = function()
                    PickupTrafficProp()
                end,
            },
            {
                title = 'Complete Setup',
                description = ('Finish traffic control (%d props placed)'):format(#PlacedTrafficProps),
                icon = 'fa-solid fa-check',
                disabled = #PlacedTrafficProps < 4,
                onSelect = function()
                    CompleteTrafficControl()
                end,
            },
        }
    })

    lib.showContext('traffic_control_menu')
    TrafficControlActive = false
end

function CompleteTrafficControl()
    if #PlacedTrafficProps < 4 then
        Bridge.Notify('Place at least 4 props to complete', 'error')
        return
    end

    if not CurrentTask then return end
    local paymentSuccess, result = lib.callback.await('dps-cityworker:server:Payment', false, CurrentTask.id)

    if paymentSuccess and result then
        -- The cones stay out for a minute, then the crew "collects" them
        SetTimeout(60000, function()
            ClearAllTrafficProps()
        end)
        TrafficBegun = nil
        finishTask(result, 'Traffic control set up!')
    else
        Bridge.Notify('The city could not sign this job off. Stay at the site and try again in a few seconds.', 'error')
    end
end

-- Cleanup traffic props on job reset
local OriginalCleanupJob = cleanupJob

cleanupJob = function()
    ClearAllTrafficProps()
    OriginalCleanupJob()
end

-- =====================================
-- WEATHER-TRIGGERED EVENTS
-- =====================================

-- Weather task bonus notification
local WeatherBonusActive = {}

RegisterNetEvent('dps-cityworker:client:WeatherTaskBonus', function(data)
    WeatherBonusActive[data.type] = true

    lib.notify({
        title = 'Weather Bonus Active',
        description = data.message,
        type = 'success',
        duration = 15000,
        icon = 'fa-solid fa-cloud-rain',
    })

    -- Bonus expires after 10 minutes
    SetTimeout(600000, function()
        WeatherBonusActive[data.type] = nil
    end)
end)

-- =====================================
-- CREW/TEAM SYSTEM
-- =====================================

-- Task assigned by foreman
RegisterNetEvent('dps-cityworker:client:TaskAssigned', function(data)
    if not isHired then return end

    -- Play notification sound
    PlaySoundFrontend(-1, "CHALLENGE_UNLOCKED", "HUD_AWARDS", true)

    lib.notify({
        title = 'Task Assigned',
        description = ('Foreman %s assigned you: %s'):format(data.assignedBy, data.label),
        type = 'inform',
        duration = 10000,
        icon = 'fa-solid fa-clipboard-list',
    })

    -- Clean up current task
    cleanupJob()

    -- Start new assigned task
    NextDelivery(data)
end)

-- Asked to join a contractor's crew: the worker decides
lib.callback.register('dps-cityworker:client:crewInvite', function(companyName)
    local answer = lib.alertDialog({
        header = 'Crew invite',
        content = ('**%s** wants you on their work crew.\n\nYour jobs in their contract area count for them, and you get a share when the contract is done.'):format(tostring(companyName)),
        centered = true,
        cancel = true,
        labels = { confirm = 'Join', cancel = 'No thanks' },
    })
    return answer == 'confirm'
end)

-- =====================================
-- JOB MENU (/citywork)
-- =====================================

local function sectorLines()
    local sectors = lib.callback.await('dps-cityworker:server:GetSectorHealth', false) or {}
    local lines = {}
    for _, info in pairs(sectors) do
        lines[#lines + 1] = ('%s: %.0f%%'):format(info.label, info.health)
    end
    table.sort(lines)
    return table.concat(lines, '  \n')
end

local function assignMenu()
    local workers = lib.callback.await('dps-cityworker:server:GetActiveWorkers', false) or {}
    local tasks = lib.callback.await('dps-cityworker:server:TaskList', false) or {}
    local me = cache.serverId
    local options = {}
    for id, w in pairs(workers) do
        if tonumber(id) ~= me then
            options[#options + 1] = {
                title = w.name or ('Worker ' .. id),
                description = w.rankLabel,
                onSelect = function()
                    local pick = {}
                    for _, t in ipairs(tasks) do
                        if (w.rank or 1) >= t.minRank then pick[#pick + 1] = { value = t.id, label = t.label } end
                    end
                    local input = lib.inputDialog('Give a job to ' .. (w.name or id), {
                        { type = 'select', label = 'Job', options = pick, required = true },
                    })
                    if not input then return end
                    local ok, msg = lib.callback.await('dps-cityworker:server:AssignWorkerTask', false, tonumber(id), input[1])
                    Bridge.Notify(msg or (ok and 'Job given' or 'Could not give that job'), ok and 'success' or 'error')
                end,
            }
        end
    end
    if #options == 0 then options[1] = { title = 'No other workers on shift', disabled = true } end
    lib.registerContext({ id = 'cityworker_assign', title = 'Give a job', menu = 'cityworker_menu', options = options })
    lib.showContext('cityworker_assign')
end

function OpenWorkMenu()
    if not isHired then
        Bridge.Notify('You are not on shift. Start work at the city depot.', 'error')
        return
    end
    local stats = lib.callback.await('dps-cityworker:server:GetPlayerStats', false) or {}
    local options = {
        {
            title = ('%s'):format(stats.rankLabel or 'City worker'),
            description = ('XP %d / %d  |  Jobs done %d  |  Earned $%d'):format(
                math.floor(stats.xp or 0), math.floor(stats.xpNeeded or 0), math.floor(stats.total_repairs or 0), math.floor(stats.total_earnings or 0)),
            icon = 'fa-solid fa-id-badge',
            readOnly = true,
        },
        {
            title = CurrentTask and ('Current job: ' .. (CurrentTask.label or 'Repair')) or 'No job right now',
            description = CurrentTask and 'Set the GPS to the work site' or 'A new job is on its way',
            icon = 'fa-solid fa-location-dot',
            disabled = not CurrentTask,
            onSelect = function()
                SetNewWaypoint(CurrentTask.location.x, CurrentTask.location.y)
                Bridge.Notify('GPS set to the work site', 'inform')
            end,
        },
        {
            title = 'Swap this job',
            description = 'For a site you cannot reach. Limited to once every few minutes.',
            icon = 'fa-solid fa-shuffle',
            disabled = not CurrentTask,
            onSelect = function()
                local ok, task = lib.callback.await('dps-cityworker:server:SkipTask', false)
                if not ok then return Bridge.Notify(task or 'You cannot swap right now', 'error') end
                cleanupJob()
                NextDelivery(task)
            end,
        },
        {
            title = 'City grid',
            description = sectorLines(),
            icon = 'fa-solid fa-bolt',
            readOnly = true,
        },
        {
            title = 'Report damage here',
            description = 'Log a fault where you are standing',
            icon = 'fa-solid fa-triangle-exclamation',
            onSelect = function()
                local input = lib.inputDialog('Report damage', {
                    { type = 'select', label = 'What is it?', required = true, default = 'general', options = {
                        { value = 'general', label = 'General damage' }, { value = 'pothole', label = 'Pothole' },
                        { value = 'streetlight', label = 'Streetlight' }, { value = 'pipe', label = 'Water pipe' },
                        { value = 'electrical', label = 'Electrical' },
                    } },
                })
                if not input then return end
                local ok, msg = lib.callback.await('dps-cityworker:server:ReportDamage', false, input[1])
                Bridge.Notify(msg or (ok and 'Reported' or 'Could not report'), ok and 'success' or 'error')
            end,
        },
    }
    if (stats.rank or 1) >= 5 then
        options[#options + 1] = {
            title = 'Control Room', description = 'Grid dashboard and crew dispatch', icon = 'fa-solid fa-tower-broadcast',
            onSelect = function() TriggerEvent('dps-cityworker:client:OpenControlRoom') end,
        }
        options[#options + 1] = {
            title = 'Give a worker a job', icon = 'fa-solid fa-people-arrows',
            onSelect = assignMenu,
        }
    end
    lib.registerContext({ id = 'cityworker_menu', title = 'City Worker', options = options })
    lib.showContext('cityworker_menu')
end

RegisterCommand('citywork', function() OpenWorkMenu() end, false)

-- Still on shift after this script restarted on the player's side: pick the job back up
CreateThread(function()
    Wait(4000)
    if isHired then return end
    local task = lib.callback.await('dps-cityworker:server:CurrentTask', false)
    if task then
        isHired = true
        NextDelivery(task)
        ShowActiveEmergencies()
    end
end)

-- Teamwork bonus indicator
local teamworkRunning = false  -- CreateThread returns nothing, so track with a flag

local function StartTeamworkCheck()
    if teamworkRunning then return end
    teamworkRunning = true

    CreateThread(function()
        local lastBonus = 0

        while isHired do
            Wait(10000) -- Check every 10 seconds

            local nearby = lib.callback.await('dps-cityworker:server:GetNearbyWorkers', false, 30.0)
            local bonusPercent = math.min(#nearby * 10, 30)

            if bonusPercent > 0 and bonusPercent ~= lastBonus then
                lib.notify({
                    title = 'Teamwork Bonus',
                    description = ('%d%% bonus active! (%d workers nearby)'):format(bonusPercent, #nearby),
                    type = 'success',
                    duration = 5000,
                    icon = 'fa-solid fa-users',
                })
                lastBonus = bonusPercent
            elseif bonusPercent == 0 and lastBonus > 0 then
                lastBonus = 0
            end
        end

        teamworkRunning = false
    end)
end

-- Auto-start teamwork check when player becomes hired
CreateThread(function()
    while true do
        Wait(5000)
        if isHired and not teamworkRunning then
            StartTeamworkCheck()
        end
    end
end)

-- =====================================
-- DISPATCH ALERTS
-- =====================================

RegisterNetEvent('dps-cityworker:client:DispatchAlert', function(data)
    if not isHired then return end

    lib.notify({
        title = 'Dispatch Alert',
        description = ('Crew needed at %s'):format(data.label),
        type = 'warning',
        duration = 10000,
    })

    -- Set GPS to dispatch location
    local alert = lib.alertDialog({
        header = 'Dispatch Alert',
        content = ('Crew requested at **%s**.\n\nSet GPS to location?'):format(data.label),
        centered = true,
        cancel = true,
        labels = { confirm = 'Set GPS', cancel = 'Ignore' }
    })

    if alert == 'confirm' then
        SetNewWaypoint(data.coords.x, data.coords.y)
        Bridge.Notify('GPS set to dispatch location', 'inform')
    end
end)

-- =====================================
-- PLAYER LOAD/UNLOAD
-- =====================================

function OnPlayerLoaded()
    -- Nothing needed on load
end

function OnPlayerUnload()
    resetJob()
end

-- =====================================
-- RESOURCE CLEANUP
-- =====================================

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        resetJob()
        SetArtificialLightsState(false)
        if ControlRoomOpen then
            SetNuiFocus(false, false)
        end
    end
end)

-- =====================================
-- EXPORTS
-- =====================================

exports('IsPlayerOnDuty', function()
    return isHired
end)

exports('GetNearestWorkZone', function()
    local playerPos = GetEntityCoords(cache.ped)
    local nearest = nil
    local nearestDist = math.huge

    for id, data in pairs(Config.Sectors) do
        local dist = #(playerPos - data.coords)
        if dist < nearestDist then
            nearest = id
            nearestDist = dist
        end
    end

    return nearest, nearestDist
end)
