-- Finds where a targeted house stands. The client gives no position for buildings
-- (UnitWorldPosition / GetUnitId are nil for them), so three things are combined:
--
--  * edge fit (best, ~0.1-0.3 m): UnitDistance("target") is the distance from the player to the
--    building's edge, not its centre (it goes negative inside). With player positions from
--    UnitWorldPosition("player") taken while walking, |player - centre| = distance + radius is
--    solved for centre and radius. It needs samples off a straight line (sideways spread).
--  * camera model (~0.3 m, works standing still): GetUnitScreenPosition("target") gives the
--    building's screen x, y and a depth. X2Util:ConvertWorldToScreen (a client global, not in the
--    addon api) is used to build the camera: four on-screen points are solved back to world rays,
--    giving the screen -> direction mapping, which also works for anchors above the screen.
--  * fallback: where the player stands (good when the distance is <= 0, i.e. inside the plot).
--
-- World x = East, y = North, in metres. Sextants: decimal degrees, W and S negative,
-- lon = x * COORD_COEF + lonOffset (offsets are worked out live from the player's own sextant).
local api = require("api")

local locate = {}

-- sextant degrees per world unit (WorldSatNav core/constants.lua)
locate.COORD_COEF = 0.00097657363894522145695357130138029

-- edge fit
-- a new distance sample is kept once the player has moved this far from the last one
local EDGE_MIN_STEP_M = 0.25
local EDGE_MAX_SAMPLES = 300
local EDGE_MIN_SAMPLES = 8
-- below this the samples are nearly on a line and the centre can slide along it
local EDGE_MIN_SIDEWAYS_M = 0.5
local EDGE_MAX_ERR_M = 0.35
local EDGE_MIN_RADIUS_M = -1
local EDGE_MAX_RADIUS_M = 25
local FIT_ITERATIONS = 60
local FIT_MAX_STEP_M = 5

-- rays: a new camera sample is only worth a ray once the player has moved this far from the last one
local RAY_MIN_STEP_M = 0.4
local RAY_MAX = 150
local RAY_MIN_COUNT = 5
-- rays must come from directions this far apart (radians, ~8 degrees) to cross cleanly
local RAY_MIN_SPREAD = 0.14
local RAY_MAX_RMS_M = 0.5
-- how far a camera-only estimate can be out (see locate.Estimate)
local CAMERA_ROUGH_M = 10
-- standing inside a building's collision box (UnitDistance <= 0): about half its width from the centre
-- (a treehouse's box was ~9 m across)
local INSIDE_M = 5
-- the camera model gives up when it never worked after this many tries
local CAMERA_MAX_FAILED_TRIES = 40

-- box fit (square / rectangular plots): refit after this many new samples, on at most this many
local BOX_REFIT_SAMPLES = 8
local BOX_MAX_FIT_SAMPLES = 120
local BOX_MIN_SAMPLES = 12
local BOX_MIN_SIDEWAYS_M = 2
local BOX_MAX_ERR_M = 0.35
local BOX_ITERATIONS = 40
-- the box (5 parameters) must beat the circle (3) by this factor to be used instead
local BOX_BETTER_FACTOR = 0.8
-- a box needs the walk to go at least half way round it (radians of the circle seen from its centre)
local BOX_MIN_COVERAGE = math.pi
-- a distance fit only counts when it lands this close to trusted rays (a partial walk round a square plot
-- fits a circle tightly in the wrong place); metres, or this many times the rays' own accuracy
local FIT_AGREE_M = 1.0
local FIT_AGREE_FACTOR = 2

-- camera model (from the old Houses locate.lua)
local NEWTON_STEP = 0.25
local MAX_NEWTON_STEP = 5
local NEWTON_ITERATIONS = 40
local SCREEN_TOLERANCE = 0.3
local DEPTH_TOLERANCE = 0.05
local REFERENCE_OFFSETS = { { -250, -250 }, { 250, -250 }, { -250, 100 }, { 250, 100 } }
local NEAR_DEPTH = 10
local FAR_DEPTH = 20
local MAX_CAMERA_SPREAD = 0.3
local MAX_PLAYER_MISS = 0.5
local MAX_DEPTH_OFFSET = 3
local CAMERA_MIN_POINTS = 3
local CAMERA_MAX_SPREAD_M = 1.0
local CAMERA_MAX_POINTS = 20

-- sextant offsets: snap to a whole degree when this close (sextant seconds are rounded)
local OFFSET_SNAP_DEG = 2 / 3600
local OFFSET_MAX_SAMPLES = 30

-- ---------------------------------------------------------------------------
-- Maths
-- ---------------------------------------------------------------------------

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function scale(a, k) return { a[1] * k, a[2] * k, a[3] * k } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function length(a) return math.sqrt(dot(a, a)) end

local function normalize(a)
	local len = length(a)
	if len < 1e-9 then
		return nil
	end
	return scale(a, 1 / len)
end

local function horizontalDistance(a, b)
	local dx, dy = a[1] - b[1], a[2] - b[2]
	return math.sqrt(dx * dx + dy * dy)
end

-- solves m * x = v for any n (Gaussian elimination, partial pivoting); nil when singular
local function solve(m, v)
	local n = #v
	local a = {}
	for row = 1, n do
		a[row] = {}
		for col = 1, n do
			a[row][col] = m[row][col]
		end
		a[row][n + 1] = v[row]
	end
	for col = 1, n do
		local pivot = col
		for row = col + 1, n do
			if math.abs(a[row][col]) > math.abs(a[pivot][col]) then
				pivot = row
			end
		end
		if math.abs(a[pivot][col]) < 1e-12 then
			return nil
		end
		a[col], a[pivot] = a[pivot], a[col]
		for row = col + 1, n do
			local factor = a[row][col] / a[col][col]
			for k = col, n + 1 do
				a[row][k] = a[row][k] - factor * a[col][k]
			end
		end
	end
	local x = {}
	for row = n, 1, -1 do
		local sum = a[row][n + 1]
		for k = row + 1, n do
			sum = sum - a[row][k] * x[k]
		end
		x[row] = sum / a[row][row]
	end
	return x
end

local function columns(c1, c2, c3)
	return {
		{ c1[1], c2[1], c3[1] },
		{ c1[2], c2[2], c3[2] },
		{ c1[3], c2[3], c3[3] },
	}
end

local function multiply(m, v)
	return {
		m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3],
		m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
		m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3],
	}
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- ---------------------------------------------------------------------------
-- Client reads
-- ---------------------------------------------------------------------------

-- the addon sandbox has no select(), so take the values straight from the call
local function unitWorld(unit)
	local ok, x, y, z = pcall(function()
		return api.Unit:UnitWorldPosition(unit)
	end)
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if not ok or x == nil or y == nil or z == nil then
		return nil
	end
	return { x, y, z }
end

local function unitScreen(unit)
	local ok, x, y, d = pcall(function()
		return api.Unit:GetUnitScreenPosition(unit)
	end)
	x, y, d = tonumber(x), tonumber(y), tonumber(d)
	if not ok or x == nil or y == nil or d == nil then
		return nil
	end
	return { x, y, d }
end

local function targetDistance()
	local ok, d = pcall(function()
		return api.Unit:UnitDistance("target")
	end)
	if not ok then
		return nil
	end
	return tonumber(d)
end

local function normalizeSextant(sextant)
	if type(sextant) ~= "table" then
		return nil
	end
	local s = {
		longitude = sextant.longitudeDir or sextant.longitude,
		latitude = sextant.latitudeDir or sextant.latitude,
		deg_long = tonumber(sextant.longitudeDeg or sextant.deg_long or sextant.degLong),
		min_long = tonumber(sextant.longitudeMin or sextant.min_long or sextant.minLong) or 0,
		sec_long = tonumber(sextant.longitudeSec or sextant.sec_long or sextant.secLong) or 0,
		deg_lat = tonumber(sextant.latitudeDeg or sextant.deg_lat or sextant.degLat),
		min_lat = tonumber(sextant.latitudeMin or sextant.min_lat or sextant.minLat) or 0,
		sec_lat = tonumber(sextant.latitudeSec or sextant.sec_lat or sextant.secLat) or 0,
	}
	if s.longitude == nil or s.latitude == nil or s.deg_long == nil or s.deg_lat == nil then
		return nil
	end
	return s
end

local function sextantToDecimal(s)
	local lon = s.deg_long + s.min_long / 60 + s.sec_long / 3600
	local lat = s.deg_lat + s.min_lat / 60 + s.sec_lat / 3600
	if s.longitude == "W" then
		lon = -lon
	end
	if s.latitude == "S" then
		lat = -lat
	end
	return lon, lat
end

local function splitDegrees(value, positiveDir, negativeDir)
	local dir = positiveDir
	if value < 0 then
		dir = negativeDir
		value = -value
	end
	local totalSeconds = math.floor(value * 3600 + 0.5)
	local deg = math.floor(totalSeconds / 3600)
	local min = math.floor((totalSeconds % 3600) / 60)
	return dir, deg, min, totalSeconds % 60
end

-- same shape as WorldSatNav's location.dat / demos.dat "location"
function locate.DecimalToSextant(lon, lat)
	local longitude, degLong, minLong, secLong = splitDegrees(lon, "E", "W")
	local latitude, degLat, minLat, secLat = splitDegrees(lat, "N", "S")
	return {
		longitude = longitude,
		deg_long = degLong,
		min_long = minLong,
		sec_long = secLong,
		latitude = latitude,
		deg_lat = degLat,
		min_lat = minLat,
		sec_lat = secLat,
	}
end

function locate.FormatSextant(s)
	-- "\194\176" is the degree sign in UTF-8
	return string.format("%s %d\194\176%d'%d\" %s %d\194\176%d'%d\"",
		s.longitude, s.deg_long, s.min_long, s.sec_long,
		s.latitude, s.deg_lat, s.min_lat, s.sec_lat)
end

-- the player's sextant, normalized, or nil
function locate.PlayerSextant()
	local ok, sextant = pcall(function()
		return api.Map:GetPlayerSextants()
	end)
	if not ok then
		return nil
	end
	return normalizeSextant(sextant)
end

-- ---------------------------------------------------------------------------
-- Camera model
-- ---------------------------------------------------------------------------

-- world point -> screen x, y, distance (distance made positive: building anchors are often off screen)
local function project(p)
	local ok, sx, sy, d = pcall(function()
		return X2Util:ConvertWorldToScreen(p[1], p[2], p[3])
	end)
	sx, sy, d = tonumber(sx), tonumber(sy), tonumber(d)
	if not ok or sx == nil or sy == nil or d == nil then
		return nil
	end
	return { sx, sy, math.abs(d) }
end

-- world point that shows at screen (sx, sy) at camera distance depth (Newton on ConvertWorldToScreen)
local function unproject(screen, start)
	local p = { start[1], start[2], start[3] }
	for _ = 1, NEWTON_ITERATIONS do
		local f = project(p)
		if f == nil then
			return nil
		end
		local e = { f[1] - screen[1], f[2] - screen[2], f[3] - screen[3] }
		if math.abs(e[1]) < SCREEN_TOLERANCE and math.abs(e[2]) < SCREEN_TOLERANCE
			and math.abs(e[3]) < DEPTH_TOLERANCE then
			return p
		end
		local jacobian = { {}, {}, {} }
		for axis = 1, 3 do
			local moved = { p[1], p[2], p[3] }
			moved[axis] = moved[axis] + NEWTON_STEP
			local fm = project(moved)
			if fm == nil then
				return nil
			end
			for row = 1, 3 do
				jacobian[row][axis] = (fm[row] - f[row]) / NEWTON_STEP
			end
		end
		local delta = solve(jacobian, e)
		if delta == nil then
			return nil
		end
		local len = length(delta)
		if len > MAX_NEWTON_STEP then
			delta = scale(delta, MAX_NEWTON_STEP / len)
		end
		p = sub(p, delta)
	end
	return nil
end

local function buildCamera(playerScreen, player)
	local screens, dirs, origins = {}, {}, {}
	for i, offset in ipairs(REFERENCE_OFFSETS) do
		local sx, sy = playerScreen[1] + offset[1], playerScreen[2] + offset[2]
		local near = unproject({ sx, sy, NEAR_DEPTH }, player)
		local far = near and unproject({ sx, sy, FAR_DEPTH }, near)
		local dir = far and normalize(sub(far, near))
		if dir == nil then
			return nil, "reference point " .. i .. " could not be solved"
		end
		screens[i] = { sx, sy, 1 }
		dirs[i] = dir
		origins[i] = sub(near, scale(dir, NEAR_DEPTH))
	end
	local position = scale(add(add(origins[1], origins[2]), add(origins[3], origins[4])), 0.25)
	for _, origin in ipairs(origins) do
		if length(sub(origin, position)) > MAX_CAMERA_SPREAD then
			return nil, "reference rays do not meet at one camera point"
		end
	end
	-- 4-point homography from screen (x, y, 1) to world direction
	local mu = solve(columns(screens[1], screens[2], screens[3]), screens[4])
	local lambda = solve(columns(dirs[1], dirs[2], dirs[3]), dirs[4])
	if mu == nil or lambda == nil then
		return nil, "reference points are degenerate"
	end
	return {
		position = position,
		screenBasis = columns(scale(screens[1], mu[1]), scale(screens[2], mu[2]), scale(screens[3], mu[3])),
		worldBasis = columns(scale(dirs[1], lambda[1]), scale(dirs[2], lambda[2]), scale(dirs[3], lambda[3])),
		forward = normalize(add(add(dirs[1], dirs[2]), add(dirs[3], dirs[4]))),
	}
end

local function cameraDirection(camera, sx, sy)
	local a = solve(camera.screenBasis, { sx, sy, 1 })
	if a == nil then
		return nil
	end
	local dir = normalize(multiply(camera.worldBasis, a))
	-- second value: true when the point is behind the camera (the direction had to be flipped)
	if dir ~= nil and dot(dir, camera.forward) < 0 then
		return scale(dir, -1), true
	end
	return dir, false
end

-- one camera-model position of the target, or nil and a reason
local function cameraPoint(player)
	local target = unitScreen("target")
	local playerScreen = unitScreen("player")
	if target == nil or playerScreen == nil then
		return nil, "no screen position"
	end
	local camera, reason = buildCamera(playerScreen, player)
	if camera == nil then
		return nil, reason
	end
	-- depth calibration: GetUnitScreenPosition's depth reads about 1 m more than the real distance
	local playerDir = cameraDirection(camera, playerScreen[1], playerScreen[2])
	local flat = playerDir and (playerDir[1] * playerDir[1] + playerDir[2] * playerDir[2]) or 0
	if flat < 1e-6 then
		return nil, "player ray is vertical"
	end
	local along = ((player[1] - camera.position[1]) * playerDir[1]
		+ (player[2] - camera.position[2]) * playerDir[2]) / flat
	local playerPoint = add(camera.position, scale(playerDir, along))
	if horizontalDistance(playerPoint, player) > MAX_PLAYER_MISS then
		return nil, "player check failed"
	end
	local depthOffset = playerScreen[3] - along
	if math.abs(depthOffset) > MAX_DEPTH_OFFSET then
		return nil, "depth offset out of range"
	end
	local targetDir, behind = cameraDirection(camera, target[1], target[2])
	if targetDir == nil then
		return nil, "no direction for the target"
	end
	if behind then
		-- its screen position is a mirror image then: neither the point nor the ray can be trusted
		return nil, "target behind the camera"
	end
	-- the ray alone (camera -> target) does not need the depth; rays from several spots cross at the target
	local ray = { camera.position[1], camera.position[2], targetDir[1], targetDir[2] }
	return add(camera.position, scale(targetDir, target[3] - depthOffset)), nil, ray
end

local function cameraEstimate(points)
	if #points < CAMERA_MIN_POINTS then
		return nil
	end
	local sum = { 0, 0 }
	local first = #points - CAMERA_MIN_POINTS + 1
	for i = first, #points do
		sum[1] = sum[1] + points[i][1]
		sum[2] = sum[2] + points[i][2]
	end
	local average = { sum[1] / CAMERA_MIN_POINTS, sum[2] / CAMERA_MIN_POINTS }
	local spread = 0
	for i = first, #points do
		spread = math.max(spread, horizontalDistance(points[i], average))
	end
	if spread > CAMERA_MAX_SPREAD_M then
		return nil
	end
	return { x = average[1], y = average[2], spread = spread }
end

-- ---------------------------------------------------------------------------
-- Edge fit
-- ---------------------------------------------------------------------------

-- Linear start for the fit: |p - c|^2 = (d + r)^2 is linear in cx, cy, r and k = |c|^2 - r^2:
-- 2 px cx + 2 py cy + 2 d r - k = px^2 + py^2 - d^2
local function linearEdge(samples)
	local ata = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
	local atb = { 0, 0, 0, 0 }
	-- relative to the first sample, to keep the numbers small
	local ox, oy = samples[1][1], samples[1][2]
	for _, s in ipairs(samples) do
		local px, py, d = s[1] - ox, s[2] - oy, s[3]
		local row = { 2 * px, 2 * py, 2 * d, -1 }
		local b = px * px + py * py - d * d
		for i = 1, 4 do
			for j = 1, 4 do
				ata[i][j] = ata[i][j] + row[i] * row[j]
			end
			atb[i] = atb[i] + row[i] * b
		end
	end
	local x = solve(ata, atb)
	if x == nil then
		return nil
	end
	return { x[1] + ox, x[2] + oy, x[3] }
end

-- Gauss-Newton on |p - c| - d - r; returns cx, cy, r, rms error
local function fitEdge(samples, start)
	local cx, cy, r = start[1], start[2], start[3]
	for _ = 1, FIT_ITERATIONS do
		local jtj = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
		local jtr = { 0, 0, 0 }
		for _, s in ipairs(samples) do
			local dx, dy = s[1] - cx, s[2] - cy
			local rho = math.sqrt(dx * dx + dy * dy)
			if rho > 1e-6 then
				local res = rho - s[3] - r
				local j = { -dx / rho, -dy / rho, -1 }
				for a = 1, 3 do
					for b = 1, 3 do
						jtj[a][b] = jtj[a][b] + j[a] * j[b]
					end
					jtr[a] = jtr[a] + j[a] * res
				end
			end
		end
		-- a little damping keeps a near-line set from blowing up
		for a = 1, 3 do
			jtj[a][a] = jtj[a][a] * 1.001 + 1e-9
		end
		local delta = solve(jtj, jtr)
		if delta == nil then
			return nil
		end
		local step = math.sqrt(delta[1] * delta[1] + delta[2] * delta[2])
		if step > FIT_MAX_STEP_M then
			local k = FIT_MAX_STEP_M / step
			delta = { delta[1] * k, delta[2] * k, delta[3] * k }
		end
		cx, cy, r = cx - delta[1], cy - delta[2], r - delta[3]
		if math.abs(delta[1]) + math.abs(delta[2]) + math.abs(delta[3]) < 1e-5 then
			break
		end
	end
	local sum = 0
	for _, s in ipairs(samples) do
		local dx, dy = s[1] - cx, s[2] - cy
		local res = math.sqrt(dx * dx + dy * dy) - s[3] - r
		sum = sum + res * res
	end
	return cx, cy, r, math.sqrt(sum / #samples)
end

-- spread of the player positions across their main walking direction
local function sidewaysSpread(samples)
	local mx, my = 0, 0
	for _, s in ipairs(samples) do
		mx, my = mx + s[1], my + s[2]
	end
	mx, my = mx / #samples, my / #samples
	local cxx, cxy, cyy = 0, 0, 0
	for _, s in ipairs(samples) do
		local dx, dy = s[1] - mx, s[2] - my
		cxx, cxy, cyy = cxx + dx * dx, cxy + dx * dy, cyy + dy * dy
	end
	local theta = 0.5 * atan2(2 * cxy, cxx - cyy) + math.pi / 2
	local nx, ny = math.cos(theta), math.sin(theta)
	local low, high = nil, nil
	for _, s in ipairs(samples) do
		local v = (s[1] - mx) * nx + (s[2] - my) * ny
		low = (low == nil or v < low) and v or low
		high = (high == nil or v > high) and v or high
	end
	return high - low
end

local function edgeEstimate(samples, hint)
	if #samples < EDGE_MIN_SAMPLES then
		return nil
	end
	local starts = {}
	-- the camera result (if any) picks the right side when the walk was close to a line
	if hint ~= nil then
		starts[#starts + 1] = { hint.x, hint.y, 1 }
	end
	local linear = linearEdge(samples)
	if linear ~= nil then
		starts[#starts + 1] = linear
	end
	local best = nil
	for _, start in ipairs(starts) do
		local cx, cy, r, err = fitEdge(samples, start)
		if cx ~= nil and err == err and (best == nil or err < best.err) then
			best = { x = cx, y = cy, radius = r, err = err }
		end
	end
	if best == nil then
		return nil
	end
	best.samples = #samples
	best.sideways = sidewaysSpread(samples)
	best.trusted = best.sideways >= EDGE_MIN_SIDEWAYS_M and best.err <= EDGE_MAX_ERR_M
		and best.radius >= EDGE_MIN_RADIUS_M and best.radius <= EDGE_MAX_RADIUS_M
	return best
end

-- ---------------------------------------------------------------------------
-- Rays: least-squares crossing point of camera -> target lines, on the ground plane
-- ---------------------------------------------------------------------------

-- rays: { cameraX, cameraY, dirX, dirY } (dir need not be unit length)
local function raysEstimate(rays)
	if #rays < RAY_MIN_COUNT then
		return nil
	end
	local lines = {}
	for _, ray in ipairs(rays) do
		local len = math.sqrt(ray[3] * ray[3] + ray[4] * ray[4])
		if len > 1e-6 then
			local dx, dy = ray[3] / len, ray[4] / len
			-- normal to the line; n . p = n . camera for every point p on it
			local nx, ny = -dy, dx
			lines[#lines + 1] = { ray[1], ray[2], dx, dy, nx, ny, nx * ray[1] + ny * ray[2] }
		end
	end
	if #lines < RAY_MIN_COUNT then
		return nil
	end
	local function crossing(set)
		local axx, axy, ayy, cx, cy = 0, 0, 0, 0, 0
		for _, line in ipairs(set) do
			axx, axy, ayy = axx + line[5] * line[5], axy + line[5] * line[6], ayy + line[6] * line[6]
			cx, cy = cx + line[5] * line[7], cy + line[6] * line[7]
		end
		return solve({ { axx, axy }, { axy, ayy } }, { cx, cy })
	end
	local p = crossing(lines)
	if p == nil then
		return nil
	end
	-- drop rays that point away from the crossing (target was behind the camera) or miss it badly, solve again
	local function residual(line, at)
		return line[5] * at[1] + line[6] * at[2] - line[7]
	end
	local sum0 = 0
	for _, line in ipairs(lines) do
		sum0 = sum0 + residual(line, p) ^ 2
	end
	local missLimit = math.max(1, 3 * math.sqrt(sum0 / #lines))
	local kept = {}
	for _, line in ipairs(lines) do
		local ahead = (p[1] - line[1]) * line[3] + (p[2] - line[2]) * line[4] > 0
		if ahead and math.abs(residual(line, p)) <= missLimit then
			kept[#kept + 1] = line
		end
	end
	if #kept < RAY_MIN_COUNT then
		return { x = p[1], y = p[2], rms = math.sqrt(sum0 / #lines), spread = 0, rays = #lines, kept = #kept,
			trusted = false, accuracy = 99 }
	end
	if #kept < #lines then
		p = crossing(kept) or p
	end
	-- how far apart the viewing directions are, around their average direction
	local mx, my = 0, 0
	for _, line in ipairs(kept) do
		mx, my = mx + line[3], my + line[4]
	end
	local mlen = math.sqrt(mx * mx + my * my)
	local low, high = 0, 0
	local sum = 0
	for _, line in ipairs(kept) do
		if mlen > 1e-9 then
			local angle = atan2(mx * line[4] - my * line[3], mx * line[3] + my * line[4])
			low, high = math.min(low, angle), math.max(high, angle)
		end
		sum = sum + residual(line, p) ^ 2
	end
	local rms = math.sqrt(sum / #kept)
	local spread = high - low
	return {
		x = p[1], y = p[2], rms = rms, spread = spread, rays = #lines, kept = #kept,
		-- most rays must survive, or the crossing is not to be believed
		trusted = #kept >= 0.7 * #lines and spread >= RAY_MIN_SPREAD and rms <= RAY_MAX_RMS_M,
		-- crossing error grows as the rays get closer to parallel
		accuracy = math.max(0.15, rms / math.max(math.sin(math.min(spread, math.pi / 2)), 0.1)),
	}
end

-- ---------------------------------------------------------------------------
-- Box fit: UnitDistance read as the signed distance to a rotated rectangle
-- ---------------------------------------------------------------------------

-- p = { cx, cy, halfA, halfB, angle }; positive outside, negative inside (as UnitDistance is)
local function boxDistance(px, py, p)
	local dx, dy = px - p[1], py - p[2]
	local c, s = math.cos(p[5]), math.sin(p[5])
	local qx = math.abs(c * dx + s * dy) - math.abs(p[3])
	local qy = math.abs(-s * dx + c * dy) - math.abs(p[4])
	local ox, oy = math.max(qx, 0), math.max(qy, 0)
	return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0)
end

local function boxCost(samples, p)
	local sum = 0
	for _, s in ipairs(samples) do
		local res = boxDistance(s[1], s[2], p) - s[3]
		sum = sum + res * res
	end
	return sum
end

-- Levenberg-Marquardt with a numeric Jacobian; returns params, rms error
local BOX_STEPS = { 1e-3, 1e-3, 1e-3, 1e-3, 1e-4 }
local function fitBox(samples, start)
	local p = { start[1], start[2], start[3], start[4], start[5] }
	local cost = boxCost(samples, p)
	local lambda = 1e-2
	for _ = 1, BOX_ITERATIONS do
		local jtj, jtr = {}, {}
		for a = 1, 5 do
			jtj[a] = { 0, 0, 0, 0, 0 }
			jtr[a] = 0
		end
		for _, s in ipairs(samples) do
			local base = boxDistance(s[1], s[2], p)
			local res = base - s[3]
			local j = {}
			for k = 1, 5 do
				local saved = p[k]
				p[k] = saved + BOX_STEPS[k]
				j[k] = (boxDistance(s[1], s[2], p) - base) / BOX_STEPS[k]
				p[k] = saved
			end
			for a = 1, 5 do
				for b = 1, 5 do
					jtj[a][b] = jtj[a][b] + j[a] * j[b]
				end
				jtr[a] = jtr[a] + j[a] * res
			end
		end
		local improved = false
		for _ = 1, 6 do
			local m = {}
			for a = 1, 5 do
				m[a] = { jtj[a][1], jtj[a][2], jtj[a][3], jtj[a][4], jtj[a][5] }
				m[a][a] = m[a][a] * (1 + lambda) + 1e-9
			end
			local delta = solve(m, jtr)
			if delta == nil then
				break
			end
			local trial = {}
			for k = 1, 5 do
				trial[k] = p[k] - delta[k]
			end
			local trialCost = boxCost(samples, trial)
			if trialCost < cost then
				local gain = cost - trialCost
				p, cost = trial, trialCost
				lambda = math.max(lambda / 3, 1e-7)
				improved = gain > 1e-10
				break
			end
			lambda = lambda * 4
		end
		if not improved then
			break
		end
	end
	return p, math.sqrt(cost / #samples)
end

-- every n-th sample, so a long walk does not make the fit slow
local function thinSamples(samples, cap)
	if #samples <= cap then
		return samples
	end
	local out = {}
	local step = #samples / cap
	for i = 1, cap do
		out[i] = samples[math.floor((i - 1) * step) + 1]
	end
	return out
end

-- how much of the circle round (cx, cy) the walk covered: 2 pi minus the biggest gap between samples
local function angularCoverage(samples, cx, cy)
	if #samples < 2 then
		return 0
	end
	local angles = {}
	for i, s in ipairs(samples) do
		angles[i] = atan2(s[2] - cy, s[1] - cx)
	end
	table.sort(angles)
	local gap = angles[1] + 2 * math.pi - angles[#angles]
	for i = 2, #angles do
		gap = math.max(gap, angles[i] - angles[i - 1])
	end
	return 2 * math.pi - gap
end

-- Fits the box from a few starting angles and sizes around centre (cx, cy). Cached on the session.
-- Only once the walk has gone at least half way round: on a shorter arc a box can be fitted almost anywhere.
local function boxEstimate(session, cx, cy, size)
	local samples = session.edge
	if #samples < BOX_MIN_SAMPLES or cx == nil then
		return nil
	end
	local coverage = angularCoverage(samples, cx, cy)
	if coverage < BOX_MIN_COVERAGE then
		return { coverage_deg = coverage * 180 / math.pi, samples = #samples, trusted = false, skipped = true }
	end
	local cache = session.box
	if cache ~= nil and cache.result ~= nil and #samples - cache.fittedAt < BOX_REFIT_SAMPLES then
		return cache.result
	end
	local fitSamples = thinSamples(samples, BOX_MAX_FIT_SAMPLES)
	local starts = {}
	if cache ~= nil and cache.params ~= nil then
		starts[#starts + 1] = cache.params
	end
	local half = math.max(size or 2, 0.5)
	for _, h in ipairs({ half, half * 0.5, half * 1.5 }) do
		for _, angle in ipairs({ 0, math.pi / 8, math.pi / 4, 3 * math.pi / 8 }) do
			starts[#starts + 1] = { cx, cy, h, h, angle }
		end
	end
	local best, bestErr = nil, nil
	for _, start in ipairs(starts) do
		local p, err = fitBox(fitSamples, start)
		if err == err and (bestErr == nil or err < bestErr) then
			best, bestErr = p, err
		end
	end
	local result = nil
	if best ~= nil then
		-- report the full error over every sample, not only the thinned ones
		local err = math.sqrt(boxCost(samples, best) / #samples)
		local a, b = math.abs(best[3]), math.abs(best[4])
		local angle = best[5] % (math.pi / 2)
		if a < b then
			a, b = b, a
			angle = (angle + math.pi / 2) % math.pi
		end
		result = {
			x = best[1], y = best[2], half_a = a, half_b = b, angle_deg = angle * 180 / math.pi, err = err,
			samples = #samples, sideways = sidewaysSpread(samples),
			coverage_deg = angularCoverage(samples, best[1], best[2]) * 180 / math.pi,
		}
		result.trusted = result.sideways >= BOX_MIN_SIDEWAYS_M and err <= BOX_MAX_ERR_M
			and b >= 0.3 and a <= EDGE_MAX_RADIUS_M and result.coverage_deg >= BOX_MIN_COVERAGE * 180 / math.pi
	end
	session.box = { fittedAt = #samples, params = best, result = result }
	return result
end

-- ---------------------------------------------------------------------------
-- Session: one per targeted house
-- ---------------------------------------------------------------------------

function locate.NewSession()
	return { edge = {}, camera = {}, rays = {}, lonOffsets = {}, latOffsets = {}, cameraTries = 0 }
end

local function pushCapped(list, value, cap)
	list[#list + 1] = value
	if #list > cap then
		table.remove(list, 1)
	end
end


-- true while running the camera model is worth it: until it has a steady point, then whenever the player
-- has moved far enough for a new ray; false once it has failed every time for a while
function locate.WantCamera(session)
	if #session.camera == 0 and session.cameraTries >= CAMERA_MAX_FAILED_TRIES then
		return false
	end
	if #session.camera < CAMERA_MIN_POINTS * 2 then
		return true
	end
	if #session.rays >= RAY_MAX or session.player == nil then
		return false
	end
	local last = session.lastRayPlayer
	return last == nil or horizontalDistance(last, session.player) >= RAY_MIN_STEP_M
end

-- true once the camera model has failed every try (the player-position fallback is then reported)
function locate.CameraGaveUp(session)
	return #session.camera == 0 and session.cameraTries >= CAMERA_MAX_FAILED_TRIES
end

-- Takes one sample. withCamera also runs the camera model (slow: many client calls).
function locate.Sample(session, withCamera)
	local player = unitWorld("player")
	if player == nil then
		return
	end
	session.player = player
	session.distance = targetDistance()

	local sextant = locate.PlayerSextant()
	if sextant ~= nil then
		local lon, lat = sextantToDecimal(sextant)
		pushCapped(session.lonOffsets, lon - player[1] * locate.COORD_COEF, OFFSET_MAX_SAMPLES)
		pushCapped(session.latOffsets, lat - player[2] * locate.COORD_COEF, OFFSET_MAX_SAMPLES)
		session.playerLon, session.playerLat = lon, lat
	end

	local d = session.distance
	if d ~= nil and #session.edge < EDGE_MAX_SAMPLES then
		local last = session.edge[#session.edge]
		if last == nil or horizontalDistance(last, player) >= EDGE_MIN_STEP_M then
			session.edge[#session.edge + 1] = { player[1], player[2], d }
		end
	end

	if withCamera then
		session.cameraTries = session.cameraTries + 1
		local ok, point, reason, ray = pcall(cameraPoint, player)
		if ok and point ~= nil then
			pushCapped(session.camera, point, CAMERA_MAX_POINTS)
			local last = session.lastRayPlayer
			if ray ~= nil and #session.rays < RAY_MAX
				and (last == nil or horizontalDistance(last, player) >= RAY_MIN_STEP_M) then
				session.rays[#session.rays + 1] = ray
				session.lastRayPlayer = { player[1], player[2] }
			end
		else
			session.cameraReason = ok and reason or tostring(point)
		end
	end
end

local function averageOffset(list)
	if #list == 0 then
		return nil
	end
	local sum = 0
	for _, v in ipairs(list) do
		sum = sum + v
	end
	local average = sum / #list
	local whole = math.floor(average + 0.5)
	if math.abs(average - whole) <= OFFSET_SNAP_DEG then
		return whole
	end
	return average
end

-- world x, y -> decimal lon, lat using the offsets seen from the player's own sextant
local function worldToDecimal(session, x, y)
	local lonOffset, latOffset = averageOffset(session.lonOffsets), averageOffset(session.latOffsets)
	if lonOffset == nil or latOffset == nil then
		return nil
	end
	return x * locate.COORD_COEF + lonOffset, y * locate.COORD_COEF + latOffset
end

locate.EDGE = "edge"
locate.BOX = "box"
locate.RAYS = "rays"
locate.CAMERA = "camera"
locate.INSIDE = "inside"
locate.PLAYER = "player"

-- methods from best to worst (edge and box are the same distance fit with a round or square collision shape)
locate.RANK = { rays = 4, edge = 3, box = 3, inside = 2, camera = 2, player = 1 }

local function round2(v)
	if v == nil then
		return nil
	end
	return math.floor(v * 100 + 0.5) / 100
end


-- Best position so far: { method, lon, lat, sextant, world, accuracy_m, edge, box, rays, camera }, or nil.
function locate.Estimate(session, footprint)
	local camera = cameraEstimate(session.camera)
	local rays = raysEstimate(session.rays)
	-- the most trusted position so far seeds the fits (and picks the right side for a near-straight walk)
	local hint = nil
	if rays ~= nil and rays.trusted then
		hint = rays
	elseif camera ~= nil then
		hint = camera
	end
	local edge = edgeEstimate(session.edge, hint)
	local seed = hint or edge
	local box = nil
	if seed ~= nil then
		local size = edge ~= nil and edge.radius or nil
		if size == nil or size < 0.5 then
			size = footprint ~= nil and footprint / 2 or 2
		end
		box = boxEstimate(session, seed.x, seed.y, size)
	end

	-- A distance fit must land near trusted rays to count. While the camera works but the rays are not
	-- trusted yet, it waits for them; only without a camera does a fit stand on its own.
	local function agreesWithRays(candidate)
		if rays == nil or not rays.trusted then
			return #session.camera == 0
		end
		local limit = math.max(FIT_AGREE_M, FIT_AGREE_FACTOR * rays.accuracy)
		return horizontalDistance({ candidate.x, candidate.y }, { rays.x, rays.y }) <= limit
	end
	local fit = nil
	if edge ~= nil and edge.trusted then
		edge.agrees = agreesWithRays(edge)
		if edge.agrees then
			fit = { method = locate.EDGE, x = edge.x, y = edge.y, err = edge.err }
		end
	end
	if box ~= nil and box.trusted then
		box.agrees = agreesWithRays(box)
		if box.agrees and (fit == nil or box.err < fit.err * BOX_BETTER_FACTOR) then
			fit = { method = locate.BOX, x = box.x, y = box.y, err = box.err }
		end
	end

	-- Rays come first: they cross at the point the client draws the building from (in game exactly on whole
	-- metres, all lines through it), while a distance fit finds the middle of the collision shape, which
	-- can sit off that point (0.59 m on a treehouse). Fits are used when there are no trusted rays.
	local result = nil
	if rays ~= nil and rays.trusted then
		result = { method = locate.RAYS, x = rays.x, y = rays.y, accuracy_m = rays.accuracy }
	elseif fit ~= nil then
		result = { method = fit.method, x = fit.x, y = fit.y, accuracy_m = math.max(0.1, fit.err) }
	elseif session.player ~= nil and session.distance ~= nil and session.distance <= 0 then
		-- standing inside the building's collision box: closer than a camera guess
		result = { method = locate.INSIDE, x = session.player[1], y = session.player[2], accuracy_m = INSIDE_M }
	elseif camera ~= nil then
		-- steady within a run but its depth can be far out: a 28x28 treehouse read ~8 m off the rays and
		-- the box fit (which agreed with each other) on three runs, so it is only a rough first guess
		result = { method = locate.CAMERA, x = camera.x, y = camera.y, accuracy_m = math.max(CAMERA_ROUGH_M, camera.spread) }
	elseif session.player ~= nil then
		-- inside the plot (distance <= 0) the player is within half a footprint of the centre
		local d = session.distance or 0
		local half = (footprint or 16) / 2
		result = { method = locate.PLAYER, x = session.player[1], y = session.player[2],
			accuracy_m = math.max(d, 0) + half }
	end
	if result == nil then
		return nil
	end
	local lon, lat = worldToDecimal(session, result.x, result.y)
	if lon == nil then
		return nil
	end
	result.lon, result.lat = lon, lat
	result.sextant = locate.DecimalToSextant(lon, lat)
	result.accuracy_m = round2(result.accuracy_m)
	result.world = { round2(result.x), round2(result.y) }
	local function offBest(x, y)
		return round2(horizontalDistance({ x, y }, { result.x, result.y }))
	end

	if edge ~= nil then
		result.edge = {
			x = round2(edge.x), y = round2(edge.y), radius = round2(edge.radius), err = round2(edge.err),
			samples = edge.samples, sideways = round2(edge.sideways), trusted = edge.trusted,
			agrees_with_rays = edge.agrees, off_best_m = offBest(edge.x, edge.y),
			coverage_deg = round2(angularCoverage(session.edge, edge.x, edge.y) * 180 / math.pi),
		}
	else
		result.edge = { samples = #session.edge }
	end
	-- the building's collision box as UnitDistance sees it (NOT the plot: a 28x28 treehouse plot measured
	-- 9.06 x 9.02), from any trusted box fit
	if box ~= nil and box.trusted then
		result.collision_box_m = { round2(2 * box.half_a), round2(2 * box.half_b) }
		-- a square looks the same every 90 degrees: report the turn within -45..45
		local turn = box.angle_deg % 90
		if turn > 45 then
			turn = turn - 90
		end
		result.collision_box_angle_deg = round2(turn)
	end
	if box ~= nil and box.skipped then
		result.box = { skipped = "walk round more", coverage_deg = round2(box.coverage_deg), samples = box.samples }
	elseif box ~= nil then
		result.box = {
			agrees_with_rays = box.agrees, coverage_deg = round2(box.coverage_deg),
			x = round2(box.x), y = round2(box.y), half_a = round2(box.half_a), half_b = round2(box.half_b),
			angle_deg = round2(box.angle_deg), err = round2(box.err), samples = box.samples,
			sideways = round2(box.sideways), trusted = box.trusted, off_best_m = offBest(box.x, box.y),
		}
	end
	if rays ~= nil then
		result.rays = {
			x = round2(rays.x), y = round2(rays.y), rms = round2(rays.rms), rays = rays.rays,
			spread_deg = round2(rays.spread * 180 / math.pi), kept = rays.kept, trusted = rays.trusted,
			off_best_m = offBest(rays.x, rays.y),
		}
	else
		result.rays = { rays = #session.rays }
	end
	if camera ~= nil then
		result.camera = { x = round2(camera.x), y = round2(camera.y), spread = round2(camera.spread),
			points = #session.camera, off_best_m = offBest(camera.x, camera.y) }
	else
		result.camera = { points = #session.camera, tries = session.cameraTries, reason = session.cameraReason }
	end
	return result
end

return locate
