return {
    -- Core Settings
    Debug = false, -- Set to true for print debugging and dev commands
    Framework = 'qb', -- 'qb' or 'esx'
    Target = 'ox_target', -- 'ox_target' or 'qb-target'
    Notify = 'ox_lib', -- 'ox_lib' or 'qb' or 'esx'

    -- Interaction Settings
    FuelScript = {
        enable = false,
        script = 'LegacyFuel', -- Name of your fuel script export
    },

    -- Boss / HQ Settings
    BossModel = `s_m_y_construct_02`,
    BossCoords = vec4(884.47, -2337.14, 29.34, 359.1),
    
    -- Economy & Contractor Settings
    Economy = {
        BasePay = 250, -- Base payment for a simple repair
        WeeklyBudget = 50000, -- Government budget allocation (Roadmap feature)
        CompanyRegistrationFee = 5000, -- Cost to register a sub-contractor company
        MaterialCost = 50, -- Cost deducted if player buys their own supplies
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
        Difficulty = { 'easy', 'easy', 'medium' }, -- default difficulty sequence
        HardDifficulty = { 'medium', 'medium', 'hard' }, -- for Specialists/High Voltage
        Input = {'e'}
    },

    -- Traffic Control Props
    Props = {
        Cone = 'prop_roadcone02a',
        Barrier = 'prop_barrier_work05',
    }
}
