-- Asynchronous asset loading.
--
-- The interesting part is the hand-off: the worker decodes and returns the
-- address of a surface, and the main thread uploads and destroys it. If that
-- ownership were confused the symptom would be a use-after-free rather than a
-- wrong image, so these tests load the same file repeatedly as well as once.
--
-- The second interesting part is the count. A load answers with a future and a
-- settled future carries an `Image` whose `_refs` says how many callers hold
-- the pixels, and the cost of getting that wrong is asymmetric and invisible
-- either way: seeded too high a surface leaks with nothing to report it, and
-- seeded too low the second caller frees pixels the first is still uploading
-- from, which raises nothing at all. So the sharing cases below assert the
-- count directly rather than only its consequences.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local files = require("tecs.io.files")
local content = require("tecs.platform.content")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local assets = require("tecs.assets")
local Future = require("tecs.Future")

local C = sdl.C

-- Four by four: the left half red, the right half green.
local FIXTURE = "spec/fixtures/split.png"

describe("assets", function()
    local window, device

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "assets", width = 64, height = 64 })
        device = Device.create(window, { debug = true })
        assets.install()
    end)

    teardown(function()
        assets.shutdown()
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("exposes string loads", function()
        assert.is_function(rawget(assets, "loadString"))
    end)

    it("returns a pending future immediately and settles it later", function()
        local loading = assets.loadImage(FIXTURE)
        assert.are.equal("pending", loading.status, "loading must not block the caller")

        assets.waitAll()
        assert.are.equal("ready", loading.status)

        local image = loading.value
        assert.is_not_nil(image.pixels)
        assert.are.equal(4, image.width)
        assert.are.equal(4, image.height)
        assert.are.equal(FIXTURE, image.path)
        image:release()
    end)

    it("decodes the actual pixels, in the right order", function()
        -- The fixture is red on the left, green on the right. Reading the
        -- decoded bytes directly catches a channel swap and a row order flip,
        -- which a size assertion cannot.
        local ffi = require("ffi")
        local loading = assets.loadImage(FIXTURE)
        assets.waitAll()

        local image = loading.value
        local bytes = ffi.cast("uint8_t *", image.pixels)
        assert.are.equal(255, bytes[0], "left half is red")
        assert.are.equal(0, bytes[1])
        assert.are.equal(0, bytes[12], "right half is green")
        assert.are.equal(255, bytes[13])
        image:release()
    end)

    it("reports a missing file as a failed future rather than raising", function()
        local loading = assets.loadImage("spec/fixtures/does-not-exist.png")
        assets.waitAll()

        assert.are.equal("failed", loading.status)
        assert.is_truthy(loading.error:find("cannot decode"))
        assert.has_error(function()
            return loading.value
        end)
    end)

    it("loads several files concurrently", function()
        -- Distinct paths, so nothing here shares a decode: what is being
        -- checked is that five tasks in the queue at once each come back to
        -- the future that asked for them, images and sounds together.
        local good = assets.loadImage(FIXTURE)
        local missingA = assets.loadImage("spec/fixtures/missing-a.png")
        local missingB = assets.loadImage("spec/fixtures/missing-b.png")
        local blip = assets.loadSound("spec/fixtures/blip.wav", "resident", 0)
        local absent = assets.loadSound("spec/fixtures/missing.wav", "auto", 0)
        assert.are.equal(5, assets.pending())

        assets.waitAll()
        assert.are.equal(0, assets.pending())
        assert.are.equal("ready", good.status)
        assert.is_not_nil(good.value.pixels)
        assert.are.equal("failed", missingA.status)
        assert.are.equal("failed", missingB.status)
        assert.are.equal("ready", blip.status)
        assert.are.equal("failed", absent.status)

        good.value:release()
        blip.value:release()
    end)

    it("gives each load its own decoded buffer", function()
        -- Surfaces are handed over by address and destroyed by the receiver.
        -- Two loads sharing pixels would mean the ownership transfer went
        -- wrong somewhere, and releasing one would corrupt the other. The
        -- first is settled before the second is asked for, so this is two
        -- decodes rather than two callers of one.
        local first = assets.loadImage(FIXTURE)
        assets.waitAll()
        local second = assets.loadImage(FIXTURE)
        assets.waitAll()

        assert.is_not_nil(first.value.pixels)
        assert.is_not_nil(second.value.pixels)
        assert.are_not.equal(tostring(first.value.pixels), tostring(second.value.pixels))

        -- Releasing one leaves the other's pixels readable, which is the
        -- property a confused hand-off would break.
        first.value:release()
        local ffi = require("ffi")
        local bytes = ffi.cast("uint8_t *", second.value.pixels)
        assert.are.equal(255, bytes[0])
        second.value:release()
    end)

    it("shares one decode between loads of a path already in flight", function()
        local first = assets.loadImage(FIXTURE)
        local second = assets.loadImage(FIXTURE)
        local third = assets.loadImage(FIXTURE)
        assert.are.equal(1, assets.pending(), "a path already being decoded must not be queued again")

        -- Each caller holds a future of its own, which is what keeps a future
        -- usable as a map key and what lets one of them cancel without the
        -- others noticing.
        assert.are_not.equal(first, second)
        assert.are_not.equal(first, third)

        assets.waitAll()
        assert.are.equal("ready", first.status)

        -- One decode, so one `Image`, and every caller holds it.
        local image = first.value
        assert.are.equal(image, second.value)
        assert.are.equal(image, third.value)
        assert.are.equal(3, image._refs, "the pixels are held by three callers")

        -- Alive until the last one lets go, counted down exactly.
        first.value:release()
        assert.are.equal(2, image._refs)
        assert.is_not_nil(image.pixels)
        second.value:release()
        assert.are.equal(1, image._refs)
        assert.is_not_nil(image.pixels)
        third.value:release()
        assert.are.equal(0, image._refs)
        assert.is_nil(image.pixels, "the last release must free")
    end)

    it("consumes no reference for a sharer that canceled in flight", function()
        -- The count is what a caller's own link increments when it settles, so
        -- a caller that gave up first never runs one. Seeding it from anything
        -- observed at settlement instead would count this caller and leak the
        -- surface with nothing to say so.
        local first = assets.loadImage(FIXTURE)
        local giving_up = assets.loadImage(FIXTURE)
        assert.are.equal(1, assets.pending())

        giving_up:cancel()
        assert.are.equal("canceled", giving_up.status)

        assets.waitAll()
        assert.are.equal("ready", first.status, "one sharer giving up must not stop the decode")
        assert.has_error(function()
            return giving_up.value
        end)

        local image = first.value
        assert.are.equal(1, image._refs, "the caller that canceled was counted anyway")
        first.value:release()
        assert.is_nil(image.pixels)
    end)

    it("abandons a decode every sharer canceled, and destroys what arrives", function()
        local first = assets.loadImage(FIXTURE)
        local second = assets.loadImage(FIXTURE)
        assert.are.equal(1, assets.pending())

        first:cancel()
        second:cancel()

        -- The queued decode is still counted, because the address the worker
        -- sends still has to be taken and destroyed.
        assert.are.equal(1, assets.pending())
        assets.waitAll()
        assert.are.equal(0, assets.pending())
        assert.has_error(function()
            return first.value
        end)
        assert.has_error(function()
            return second.value
        end)

        -- And the path is free again, so the next load decodes rather than
        -- joining something nobody wanted.
        local again = assets.loadImage(FIXTURE)
        assets.waitAll()
        assert.are.equal("ready", again.status)
        again.value:release()
    end)

    it("frees at the last release with a link of a caller's own on the load", function()
        -- A caller is free to build on what it was handed, and a link is not a
        -- holder of the pixels: only a load is. A count taken from the future's
        -- watchers instead of from the links that actually ran would read three
        -- here and never free.
        local loading = assets.loadImage(FIXTURE)
        local widths = loading:map(function(image)
            return image.width
        end)
        local also = loading:map(function(image)
            return image.height
        end)

        assets.waitAll()
        assert.are.equal(4, widths.value)
        assert.are.equal(4, also.value)

        local image = loading.value
        assert.are.equal(1, image._refs, "a map link is not a holder of the pixels")
        image:release()
        assert.is_nil(image.pixels)
    end)

    it("decodes again once an earlier load has settled", function()
        local first = assets.loadImage(FIXTURE)
        assets.waitAll()
        first.value:release()

        -- Nothing here is a cache, so a settled load is never joined.
        local second = assets.loadImage(FIXTURE)
        assert.are_not.equal(first, second)
        assets.waitAll()
        assert.are.equal("ready", second.status)
        assert.are_not.equal(first.value, second.value)
        second.value:release()
    end)

    it("reports a released image as holding nothing", function()
        local loading = assets.loadImage(FIXTURE)
        assets.waitAll()
        local image = loading.value
        image:release()

        assert.is_nil(image.pixels, "a released image must not read as uploadable")

        -- Releasing twice must not free twice, which is a double free rather
        -- than a leak and would take the process with it.
        image:release()
        assert.are.equal(0, image._refs)
        assert.is_nil(image.pixels)
    end)

    it("settles the transforms in the order the worker answered", function()
        -- Order is load bearing rather than cosmetic: a listener that registers
        -- an image allocates through a shelf packer whose coordinates depend on
        -- arrival order and end up in a `Sprite` a snapshot stores. One worker
        -- takes its tasks off a FIFO channel and answers on another, so the
        -- order it answers in is the order these were queued in, and what is
        -- being held here is that the drain does not reorder them on top.
        local settled = {}
        local paths = {
            "spec/fixtures/order-a.png",
            FIXTURE,
            "spec/fixtures/order-c.png",
        }
        for index = 1, #paths do
            local at = index
            assets.loadImage(paths[index]):onSettle(function(loaded)
                settled[#settled + 1] = at
                if loaded.status == "ready" then
                    loaded.value:release()
                end
            end)
        end

        assets.waitAll()
        assert.are.same({ 1, 2, 3 }, settled, "the drain answered out of order")

        -- Registration order within one future, which is the other half of the
        -- same rule: a link's slot is where it was appended and stays there.
        local order = {}
        local loading = assets.loadImage("spec/fixtures/order-d.png")
        for index = 1, 3 do
            local at = index
            loading:onSettle(function()
                order[#order + 1] = at
            end)
        end
        assets.waitAll()
        assert.are.same({ 1, 2, 3 }, order, "listeners ran out of registration order")
    end)

    it("joins a set of loads into one future", function()
        local joined = Future.all({
            assets.loadImage(FIXTURE),
            assets.loadImage(FIXTURE),
        })
        assets.waitAll()

        assert.are.equal("ready", joined.status)
        local images = joined.value
        assert.are.equal(2, #images)
        assert.are.equal(images[1], images[2], "one decode, joined twice")
        assert.are.equal(2, images[1]._refs)
        images[1]:release()
        images[2]:release()
        assert.is_nil(images[1].pixels)
    end)

    it("reads bytes in the background and isolates callers sharing the read", function()
        local first = assets.loadString("spec/fixtures/test_material.glsl")
        local canceled = assets.loadString("spec/fixtures/test_material.glsl")

        assert.are.equal("pending", first.status)
        assert.are_not.equal(first, canceled)
        assert.are.equal(1, assets.pending(), "one path queued two reads")

        canceled:cancel()
        assets.waitAll()

        assert.are.equal("ready", first.status)
        assert.is_truthy(first.value:find("material", 1, true))
        assert.are.equal("canceled", canceled.status)
        assert.has_error(function()
            return canceled.value
        end)
    end)

    it("keeps byte reads separate from image decodes of the same path", function()
        local image = assets.loadImage(FIXTURE)
        local bytes = assets.loadString(FIXTURE)

        assert.are.equal(2, assets.pending(), "the byte reader joined an image future")
        assets.waitAll()

        assert.are.equal("ready", image.status)
        assert.are.equal("ready", bytes.status)
        assert.are.equal("PNG", bytes.value:sub(2, 4))
        assert.is_truthy(bytes.value:find("\0", 1, true), "the worker cut bytes at the first NUL")
        image.value:release()
    end)

    it("reports a missing byte source through its future", function()
        local loading = assets.loadString("spec/fixtures/does-not-exist.data")
        assets.waitAll()

        assert.are.equal("failed", loading.status)
        assert.is_truthy(loading.error:find("cannot read", 1, true))
        assert.has_error(function()
            return loading.value
        end)
    end)

    it("reads a file's bytes, whatever they are", function()
        -- A PNG rather than a text file on purpose: the result has to carry
        -- its own length, or every binary sidecar read through here would be
        -- cut at the first NUL and only the parser would find out.
        local bytes = files.read(FIXTURE)
        assert.is_string(bytes)
        assert.are.equal("PNG", bytes:sub(2, 4))
        assert.is_truthy(bytes:find("\0", 1, true), "the fixture has NULs in it")

        local file = assert(io.open(FIXTURE, "rb"))
        local whole = file:read("*a")
        file:close()
        assert.are.equal(#whole, #bytes)
        assert.are.equal(whole, bytes)
    end)

    it("answers nil for a path with no file", function()
        assert.is_nil(files.read("spec/fixtures/does-not-exist.json"))
    end)

    it("reports nothing to do when idle", function()
        assert.are.equal(0, assets.pending())
        assert.are.equal(0, assets.update())
    end)

    -- The property that makes a drain a barrier and a join not one. The loader
    -- asks whether anything is outstanding after a result has run its listeners
    -- rather than inside the settlement, so a load one of those listeners starts
    -- is already counted by the time the question is put. A join cannot do this:
    -- it reads its inputs once, so the second load is not among them and the
    -- wait answers with a decode in flight. `Audio:destroy` frees a mixer on the
    -- strength of this, so it is asserted rather than assumed.
    it("keeps waiting for a load that a settled listener started", function()
        local first = assets.loadImage(FIXTURE)
        local second
        first:onSettle(function()
            second = assets.loadImage(FIXTURE)
        end)

        assets.waitAll()

        assert.is_not_nil(second, "the listener never ran")
        assert.are.equal("ready", second.status, "the wait answered with a decode still in flight")
        assert.are.equal(0, assets.pending())
        first.value:release()
        second.value:release()
    end)

    -- An idempotent install keeps the worker and channels serving an already
    -- queued load.
    it("installs once however many times it is asked", function()
        local loading = assets.loadImage(FIXTURE)
        assets.install()

        assets.waitAll(2000)
        assert.are.equal("ready", loading.status, "the decode answered a worker nobody was reading")
        loading.value:release()
    end)

    -- The wait spends a budget of time, not a count of pumps. A pump returns
    -- as soon as one message has arrived, so subtracting its nominal 16 ms
    -- whatever it actually cost turns the budget into a message count: these
    -- sixty answers arrive in a few milliseconds together, and a "400 ms" wait
    -- spent by subtraction gives up after twenty-five of them.
    it("waits for a budget of time rather than a count of pumps", function()
        local loads = {}
        for index = 1, 60 do
            loads[index] = assets.loadImage(("spec/fixtures/missing-%d.png"):format(index))
        end
        assert.are.equal(60, assets.pending())

        local before = tonumber(C.SDL_GetTicks())
        assets.waitAll(400)
        local elapsed = tonumber(C.SDL_GetTicks()) - before

        assert.are.equal(
            0,
            assets.pending(),
            ("the wait gave up after %d ms with loads still in flight"):format(elapsed)
        )
        for index = 1, 60 do
            assert.are.equal("failed", loads[index].status)
        end
    end)

    it("records what it read, and under what kind", function()
        local loading = assets.loadImage(FIXTURE)
        assets.waitAll()
        loading.value:release()
        files.read(FIXTURE)

        -- The kind is the one it was first asked for under, so reading an
        -- image's bytes afterwards does not turn it into a document.
        local loaded = content.loaded()
        assert.are.equal("image", loaded[FIXTURE])
        assert.are.equal("document", loaded["spec/fixtures/test_material.glsl"] or "document")
        assert.is_nil(loaded["spec/fixtures/does-not-exist.json"], "a path with no file was not read")
    end)
end)
