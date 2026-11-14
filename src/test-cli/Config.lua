--------------------------------------------------------------------------------
-- File:         test-cli/Config.lua
--
-- Description:  Everything the run is derived from: paths, the image selection,
--               the case list, the tool profiles and the parallelism. Built
--               once, identically in the parent and in every worker -- which is
--               what lets a worker reconstruct its shard from nothing but a few
--               environment variables.
--
--               Env:
--                 TEST_CLI_TOOL   profile in the test role (default lexiftool)
--                 TEST_CLI_TRACK  read|write|dir|stay|expr|all   (which groups to run)
--                 TEST_CLI_SCOPE  all = full cross product
--                 TEST_CLI_IMAGES glob list (e.g. '*.jpg *.png')
--                 TEST_CLI_LIMIT  max number of images
--                 TEST_CLI_JOBS   worker count, or 'auto'
--                 TEST_CLI_REGEN  1 = rebuild the reference tree from scratch
--                 TEST_CLI_PHASE / _WORKER / _NWORKERS  set for worker processes
--------------------------------------------------------------------------------

local TestLib  = require('test.TestLib')
local Util     = require('test-cli.Util')
local Cases    = require('test-cli.Cases')
local Profiles = require('test-cli.Profiles')

local Config = {}

local function collectImages(imagesDir, extraDir, pattern, limit)
    local imgs = {}
    -- The vendored directory holds nothing but images, so everything counts.
    -- Ours also holds its README, so only the `lex_`-prefixed files do -- which
    -- makes the naming rule enforced rather than merely documented.
    for _, dir in ipairs({ { imagesDir, nil }, { extraDir, 'lex_' } }) do
        for _, path in ipairs(Util.listFiles(dir[1], function(name)
            return not dir[2] or name:sub(1, #dir[2]) == dir[2]
        end)) do
            imgs[#imgs + 1] = path
        end
    end
    if pattern then
        local pats = {}
        for w in pattern:gmatch('%S+') do
            pats[#pats + 1] = '^' .. w:gsub('%*', '.*') .. '$'
        end
        local filtered = {}
        for _, path in ipairs(imgs) do
            local base = path:match('[^/]+$')
            for _, pat in ipairs(pats) do
                if base:match(pat) then filtered[#filtered + 1] = path; break end
            end
        end
        imgs = filtered
    end
    if limit then
        local cut = {}
        for i = 1, math.min(limit, #imgs) do cut[#cut + 1] = imgs[i] end
        imgs = cut
    end
    return imgs
end

function Config.load()
    local cfg = {}

    -- Force an absolute repository root. The upstream exiftool canonicalises
    -- the file path it is given and reports an absolute Directory, while
    -- lexiftool reports the path verbatim. With a relative root the two would
    -- differ on the Directory/File Name lines even for identical metadata.
    local repoDir = TestLib.REPO_DIR
    if repoDir:sub(1, 1) ~= '/' and not repoDir:match('^%a:[/\\]') then
        local ok, lfs = pcall(require, 'lfs')
        local cwd = ok and lfs.currentdir() or (os.getenv('PWD') or '.')
        repoDir = cwd .. '/' .. repoDir
    end
    cfg.repoDir = repoDir
    -- The harness lives in repo/src/test-cli; its observation trees and
    -- scratch belong to the same repository, so a checkout is self-contained.
    local workDir = repoDir
    cfg.workDir = workDir
    cfg.imagesDir = TestLib.T_DIR .. '/images'
    -- This port's own test images, for code paths the vendored corpus does not
    -- reach at all. A second source directory, never a modification of the
    -- vendored one; their `lex_` prefix keeps their basenames -- on which the
    -- tree layout and CORE_IMAGES are keyed -- distinct from every upstream one.
    cfg.extraImagesDir = repoDir .. '/src/test/images'
    cfg.srcImage = cfg.imagesDir .. '/ExifTool.jpg'

    cfg.refTree = workDir .. '/test-cli-ref'
    cfg.outTree = workDir .. '/test-cli-out'
    -- Scratch that must not pollute either tree: FIFO and worker logs.
    cfg.runDir = workDir .. '/build/test-cli'

    cfg.regen = os.getenv('TEST_CLI_REGEN') and true or false
    cfg.allScope = (os.getenv('TEST_CLI_SCOPE') or '') == 'all'
    cfg.mode = cfg.regen and 'gen' or 'compare'

    local track = os.getenv('TEST_CLI_TRACK') or 'all'
    cfg.track = track
    cfg.groups = {}
    for _, g in ipairs(Cases.GROUPS) do
        cfg.groups[g.name] = (track == 'all' or track == g.name)
    end

    -- Worker identity. A worker rebuilds this same config and runs its shard.
    cfg.phase = os.getenv('TEST_CLI_PHASE')
    cfg.workerId = tonumber(os.getenv('TEST_CLI_WORKER') or '')
    cfg.nworkers = math.max(1, tonumber(os.getenv('TEST_CLI_NWORKERS') or '') or 1)
    cfg.isWorker = cfg.workerId ~= nil

    local jobs = os.getenv('TEST_CLI_JOBS')
    if jobs == nil or jobs == '' or jobs == 'auto' then
        cfg.jobs = Util.cpuCount()
    else
        cfg.jobs = math.max(1, math.floor(tonumber(jobs) or 1))
    end

    cfg.luaBin = arg[-1] or 'lua'
    cfg.script = arg[0]

    cfg.profiles = Profiles.build({
        repoDir      = repoDir,
        luaBin       = cfg.luaBin,
        lexiftool    = repoDir .. '/lexiftool',
        perlBin      = os.getenv('TEST_CLI_PERL') ~= '' and os.getenv('TEST_CLI_PERL') or 'perl',
        perlLib      = repoDir .. '/vendor/exiftool/lib',
        perlExiftool = repoDir .. '/vendor/exiftool/exiftool',
    })
    cfg.perlExiftool = repoDir .. '/vendor/exiftool/exiftool'

    local testName = os.getenv('TEST_CLI_TOOL')
    if testName == nil or testName == '' then testName = 'lexiftool' end
    cfg.test = cfg.profiles[testName]
    cfg.ref = cfg.profiles[Profiles.REFERENCE]
    if not cfg.test then
        local names = {}
        for k in pairs(cfg.profiles) do names[#names + 1] = k end
        table.sort(names)
        io.stderr:write('test-cli: unknown TEST_CLI_TOOL "' .. testName .. '"; known: ' ..
                        table.concat(names, ', ') .. '\n')
        os.exit(2)
    end

    -- Every image by basename, before any TEST_CLI_IMAGES/LIMIT filter: what a
    -- variant's explicit `images` list is resolved against.
    cfg.knownImages = {}
    for _, img in ipairs(collectImages(cfg.imagesDir, cfg.extraImagesDir)) do
        cfg.knownImages[img:match('[^/]+$')] = img
    end
    cfg.images = collectImages(cfg.imagesDir, cfg.extraImagesDir,
                               os.getenv('TEST_CLI_IMAGES'),
                               tonumber(os.getenv('TEST_CLI_LIMIT') or ''))
    if #cfg.images == 0 then
        io.stderr:write('test-cli: no test images found under ' .. cfg.imagesDir .. '\n')
        os.exit(2)
    end

    -- The core subset: one representative per format family. With a narrow
    -- TEST_CLI_IMAGES/LIMIT selection none may survive; falling back to the
    -- selection keeps such runs meaningful.
    local wanted = {}
    for _, n in ipairs(Cases.CORE_IMAGES) do wanted[n] = true end
    cfg.coreImages = {}
    for _, img in ipairs(cfg.images) do
        if wanted[img:match('[^/]+$')] then
            cfg.coreImages[#cfg.coreImages + 1] = img
        end
    end
    if #cfg.coreImages == 0 then cfg.coreImages = cfg.images end

    local okBuild, cases = pcall(Cases.build, {
        images = cfg.images, coreImages = cfg.coreImages, known = cfg.knownImages,
        groups = cfg.groups, allScope = cfg.allScope,
    })
    if not okBuild then
        io.stderr:write('test-cli: ' .. tostring(cases) .. '\n')
        os.exit(2)
    end
    cfg.cases = cases

    cfg.driverCfg = {
        repoDir = cfg.repoDir, workDir = cfg.workDir, imagesDir = cfg.imagesDir,
        srcImage = cfg.srcImage,
    }
    return cfg
end

-- The vendored exiftool's version, for the tree manifest. One perl start, so
-- only the parent asks.
function Config.exiftoolVersion(cfg)
    local argv = { table.unpack(cfg.ref.argv) }
    argv[#argv + 1] = '-ver'
    return (Util.runCapture(argv):gsub('%s+$', ''))
end

-- How many cases each group contributes, for the banner.
function Config.groupCounts(cfg)
    local counts, order = {}, {}
    for _, case in ipairs(cfg.cases) do
        if not counts[case.group] then
            counts[case.group] = 0
            order[#order + 1] = case.group
        end
        counts[case.group] = counts[case.group] + 1
    end
    return counts, order
end

return Config
