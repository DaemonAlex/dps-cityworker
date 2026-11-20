return {
    -- Core Settings
    Debug = false, -- Set to true for print debugging and dev commands
    Framework = 'auto', -- 'auto', 'qbx', 'qb', or 'esx' (auto-detects QBox first)
    Inventory = 'auto', -- 'auto', 'ox', 'qs', 'codem', or 'default' (auto-detects)
    Target = 'ox_target', -- 'ox_target' or 'qb-target'
    Notify = 'ox_lib', -- 'ox_lib' or 'qb' or 'esx'

    -- Fuel Script Support (auto-detects if 'auto')
    FuelScript = {
        enable = true,
        script = 'auto', -- 'auto', 'LegacyFuel', 'ox_fuel', 'ps-fuel', 'cdn-fuel', 'qs-fuelstations'
    },

    -- Boss / HQ Settings
    BossModel = `s_m_y_construct_02`,
    -- Where the boss stands until an admin stands on the spot and runs /cityspot depot
    BossCoords = vec4(884.47, -2337.14, 29.34, 359.1),
    
    -- Economy & Contractor Settings
    Economy = {
        BasePay = 250, -- Base payment for a simple repair
        Currency = 'cash', -- Account type for payments ('cash', 'bank', 'black_money')
        WeeklyBudget = 50000, -- Government budget allocation (Roadmap feature)
        CompanyRegistrationFee = 5000, -- Cost to register a sub-contractor company
        MaterialCost = 50, -- Cost deducted if player buys their own supplies
        TravelPayPer100m = 8, -- Driving money: paid per 100 m between where the job was handed out and the site
        TravelPayMax = 400,   -- Most driving money one job can pay
    },

    -- Job rules. The server keeps a ticket for every job and only pays against it.
    Task = {
        seconds = { easy = 6, medium = 8, hard = 12 }, -- how long the work takes, by difficulty
        minTravel = 150.0,    -- a new job is at least this far from where the worker stands
        truckDistance = 80.0, -- the work truck must be this close to the site (0 = truck not needed)
        entryDistance = 15.0, -- manholes: how close to the street manhole counts as "there"
        noTruck = { manhole = true }, -- jobs that never need the truck near (manholes can be down in the tunnels)
        skipCooldown = 600,   -- seconds between swapping a job you cannot reach
        truckCooldown = 120,  -- seconds between replacement trucks at the depot
        needyBelow = 60,      -- a sector under this health gets half of the new jobs
    },
    TaskCompleteDistance = 12.0, -- how close to the site the worker must be
    EmergencyDistance = 20.0,    -- how close to an emergency the worker must be
    SectorReach = 3000.0,        -- a site outside every sector counts for the nearest one within this distance

    -- Scavenging System (find materials while working)
    ItemDrops = {
        enabled = true,
        chance = 40, -- % chance per task to find an item
        items = {
            -- { name = 'item_spawn_name', min = qty, max = qty, chance = weight }
            { name = 'copper',       min = 1, max = 3, chance = 50 }, -- Common
            { name = 'plastic',      min = 1, max = 4, chance = 30 },
            { name = 'metalscrap',   min = 2, max = 5, chance = 30 },
            { name = 'salvaged_electronics', min = 1, max = 1, chance = 10 }, -- Rare
            { name = 'steel',        min = 1, max = 2, chance = 5 },  -- Very Rare
        },
    },

    -- Seniority / Progression System
    -- Higher ranks = harder skill checks but more pay and access to better tools
    Ranks = {
        [1] = { label = 'Probationary Laborer', payMultiplier = 1.0, canAssign = false },
        [2] = { label = 'Junior Technician', payMultiplier = 1.2, canAssign = false },
        [3] = { label = 'Senior Technician', payMultiplier = 1.5, canAssign = false },
        [4] = { label = 'Specialist', payMultiplier = 1.8, canAssign = false },
        [5] = { label = 'Foreman', payMultiplier = 2.5, canAssign = true }, -- Can access Control Room
    },

    -- Strategic Grid Management (Sectors)
    -- Defines the zones for the "Control Room" UI
    Sectors = {
        ['legion'] = {
            label = "Legion Square",
            coords = vec3(188.0, -923.0, 30.0),
            radius = 300.0,
            decayRate = 0.5, -- % health lost per hour
            blackoutThreshold = 0 -- If health hits 0, lights go out
        },
        ['mirror_park'] = {
            label = "Mirror Park",
            coords = vec3(1065.0, -716.0, 57.0),
            radius = 400.0,
            decayRate = 0.3,
            blackoutThreshold = 0
        },
        ['sandy_shores'] = {
            label = "Sandy Shores",
            coords = vec3(1863.0, 3704.0, 33.0),
            radius = 600.0,
            decayRate = 0.8, -- Decays faster (old infrastructure)
            blackoutThreshold = 10 -- Lights flicker/fail at 10%
        },
    },

    -- Minigame / Skill Check Settings
    SkillCheck = {
        Difficulty = { 'easy', 'easy', 'medium' }, -- used by jobs that have no check list of their own
        Input = {'e'}
    },

    -- Task Props (the marker put out at a work site)
    -- Every name here was checked against the GTA V object list on 2026-11-20.
    -- A name the game does not have falls back to a road cone.
    TaskProps = {
        pipe = 'prop_pipes_01a',
        pothole = 'prop_roadcone02a',
        meter_reading = 'prop_toolchest_05',
        hydrant = false,           -- false = no marker: the spot is a real one in the world
        manhole = 'prop_roadcone02a',
        storm_drain = 'prop_barrier_work06a',
        electrical = false,
        transformer = 'prop_sub_trans_01a',
        bridge_inspection = 'prop_roadcone02a',
        utility_locating = 'prop_roadcone02a',

        -- Emergencies
        water_main = 'prop_pipes_01a',
        gas_leak = 'prop_barrel_02a',
        downed_lines = 'prop_worklight_03a',
        fallen_tree = 'prop_tree_fallen_02',
    },

    -- Animation dictionaries per task category
    TaskAnimations = {
        maintenance = { dict = 'amb@world_human_welding@male@base', anim = 'base' },
        road = { dict = 'amb@world_human_const_drill@male@drill@base', anim = 'base' },
        electrical = { dict = 'anim@heists@prison_heiststation@cop_reactions', anim = 'yourface' },
        cleanup = { dict = 'timetable@floyd@clean_kitchen@base', anim = 'base' },
        utility = { dict = 'amb@world_human_clipboard@male@base', anim = 'base' },
        sewer = { dict = 'mini@repair', anim = 'fixing_a_ped' },
        emergency = { dict = 'amb@world_human_welding@male@base', anim = 'base' },
    },

    -- Emergency Settings
    Emergency = {
        RandomChance = 15, -- % chance per check (every 10 min)
        BonusMultiplier = 1.5, -- XP bonus for emergency response
        PaymentMultiplier = 2.0, -- Payment bonus for emergency
        MaxActivePerSector = 1, -- Only one emergency per sector
        WorkSeconds = 15,       -- how long the emergency repair takes
        WeatherCooldown = 900,  -- seconds between weather events (storm emergencies, rain bonus)
    },

    -- Sub-Contractor Company System
    -- Senior workers register a company, accept city maintenance contracts,
    -- fulfil them with their crew's completed tasks, and get paid a lump sum.
    Contractor = {
        enable = true,
        minRankToRegister = 3,      -- Senior Technician+ can found a company
        maxOpenContracts = 3,       -- how many open contracts exist at once
        contractDeadline = 3600,    -- seconds to complete an accepted contract (1h)
        targetTasksRange = { 5, 12 }, -- a contract needs N jobs completed in its sector
        budgetPerTask = 400,        -- contract reward = target tasks * this
        reputationPerContract = 10, -- rep gained per completed contract
        reputationOnExpire = 5,     -- rep lost if a contract expires
        employeeCut = 0.15,         -- share of the budget split among online crew on completion
        withdrawAccount = 'bank',   -- account funds are withdrawn to
        bossPed = true,             -- spawn a targetable office ped at BossCoords
        hireDistance = 10.0,        -- a worker must be this close, on shift, and say yes to join a crew
    },
}
