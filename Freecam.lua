--!nonstrict
------------------------------------------------------------------------
-- Freecam (Standalone)
-- Cinematic free camera for spectating and video production.
-- No external dependencies. Toggle: Shift+L or F / DPadLeft.
------------------------------------------------------------------------

-- DUPLICATE INSTANCE KILL SWITCH
-- If a previous instance of this script is already running, fully stop it
-- (unbind all RenderStep/ContextAction/connections) before this instance starts.
do
	local CoreGui = game:GetService("CoreGui")
	local MARKER_NAME = "__FreecamRunning_Marker"

	local existingMarker = CoreGui:FindFirstChild(MARKER_NAME)
	if existingMarker then
		local killFn = existingMarker:GetAttribute("KillRef")
		-- Attributes cannot store functions, so the actual function lives in _G,
		-- keyed by a unique id stored on the marker instance.
		local killId = existingMarker:GetAttribute("KillId")
		if killId and _G["__FreecamKill_" .. killId] then
			local ok, err = pcall(_G["__FreecamKill_" .. killId])
			if not ok then
				warn("[Freecam] Failed to fully stop previous instance: " .. tostring(err))
			end
			_G["__FreecamKill_" .. killId] = nil
		end
		existingMarker:Destroy()
	end
end

local pi = math.pi
local abs = math.abs
local clamp = math.clamp
local exp = math.exp
local rad = math.rad
local sign = math.sign
local sqrt = math.sqrt
local tan = math.tan

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Settings = UserSettings()
local GameSettings = Settings.GameSettings
local Lighting = game:GetService("Lighting")
local Debris = game:GetService('Debris')
local HttpService = game:GetService("HttpService")

------------------------------------------------------------------------
-- Config persistence (executor file I/O). Silently no-ops if writefile/
-- readfile/isfile are unavailable (e.g. running in Studio or a normal client).
------------------------------------------------------------------------

local CONFIG_PATH = "Freecam_Config.json"

local Config = {}
do
	local hasFileIO = typeof(writefile) == "function"
		and typeof(readfile) == "function"
		and typeof(isfile) == "function"

	local DEFAULTS = {
		GuiKeybind = "P",
		FreecamKeybind = "LeftShift+L",
	}

	function Config.Load()
		if not hasFileIO then
			return table.clone(DEFAULTS)
		end

		local ok, result = pcall(function()
			if not isfile(CONFIG_PATH) then
				return nil
			end
			local raw = readfile(CONFIG_PATH)
			return HttpService:JSONDecode(raw)
		end)

		if not ok or typeof(result) ~= "table" then
			return table.clone(DEFAULTS)
		end

		-- Fill in any missing keys with defaults (forward-compat if we add fields later)
		for key, value in pairs(DEFAULTS) do
			if result[key] == nil then
				result[key] = value
			end
		end

		return result
	end

	function Config.Save(data)
		if not hasFileIO then
			return false
		end

		local ok, err = pcall(function()
			local encoded = HttpService:JSONEncode(data)
			writefile(CONFIG_PATH, encoded)
		end)

		if not ok then
			warn("[Freecam] Failed to save config: " .. tostring(err))
			return false
		end

		return true
	end
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	LocalPlayer = Players.LocalPlayer
end

local Camera = Workspace.CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local newCamera = Workspace.CurrentCamera
	if newCamera then
		Camera = newCamera
	end
end)


local FreecamDepthOfField = nil

local FFlagUserExitFreecamBreaksWithShiftlock
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserExitFreecamBreaksWithShiftlock")
	end)
	FFlagUserExitFreecamBreaksWithShiftlock = success and result
end

local FFlagUserShowGuiHideToggles
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserShowGuiHideToggles")
	end)
	FFlagUserShowGuiHideToggles = success and result
end

local FFlagUserFixFreecamDeltaTimeCalculation
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFixFreecamDeltaTimeCalculation")
	end)
	FFlagUserFixFreecamDeltaTimeCalculation = success and result
end

local FFlagUserFixFreecamGuiChangeVisibility
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFixFreecamGuiChangeVisibility")
	end)
	FFlagUserFixFreecamGuiChangeVisibility = success and result
end

local FFlagUserFreecamControlSpeed
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFreecamControlSpeed")
	end)
	FFlagUserFreecamControlSpeed = success and result
end

local FFlagUserFreecamTiltControl
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFreecamTiltControl")
	end)
	FFlagUserFreecamTiltControl = success and result
end

local FFlagUserFreecamSmoothnessControl
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFreecamSmoothnessControl")
	end)
	FFlagUserFreecamSmoothnessControl = success and result
end

local FFlagUserFreecamGuiDestabilization
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFreecamGuiDestabilization")
	end)
	FFlagUserFreecamGuiDestabilization = success and result
end

local FFlagUserFreecamDepthOfFieldEffect
do
	local success, result = pcall(function()
		return UserSettings():IsUserFeatureEnabled("UserFreecamDepthOfFieldEffect")
	end)
	FFlagUserFreecamDepthOfFieldEffect = success and result
end

------------------------------------------------------------------------

local FREECAM_ENABLED_ATTRIBUTE_NAME = "FreecamEnabled"
local TOGGLE_INPUT_PRIORITY = Enum.ContextActionPriority.Low.Value
local INPUT_PRIORITY = Enum.ContextActionPriority.High.Value

-- Keybind helpers: convert between "LeftShift+L" style strings (used for JSON
-- persistence and GUI display) and arrays of Enum.KeyCode (used by the macro
-- checker). The last entry in a macro array is treated as the "trigger" key;
-- earlier entries are modifier keys that must be held down.
local function KeybindStringToArray(str)
	local result = {}
	for part in string.gmatch(str, "[^%+]+") do
		local keyCode = Enum.KeyCode[part]
		if keyCode then
			table.insert(result, keyCode)
		end
	end
	if #result == 0 then
		return nil
	end
	return result
end

local function KeybindArrayToString(arr)
	local parts = {}
	for _, keyCode in ipairs(arr) do
		table.insert(parts, keyCode.Name)
	end
	return table.concat(parts, "+")
end

-- Mutable, rebindable at runtime. Defaults match the original hardcoded values.
local FREECAM_MACRO_KB = { Enum.KeyCode.LeftShift, Enum.KeyCode.P }
local GUI_TOGGLE_KB = { Enum.KeyCode.P }

local FREECAM_TILT_RESET_KB = {
	[Enum.KeyCode.Z] = true,
	[Enum.KeyCode.C] = true,
}
local FREECAM_TILT_RESET_GP = {
	[Enum.KeyCode.ButtonL1] = true,
	[Enum.KeyCode.ButtonR1] = true,
}
local FREECAM_DOF_TOGGLE = {
	[Enum.KeyCode.BackSlash] = true,
}

local NAV_GAIN = Vector3.new(1, 1, 1) * 64
local PAN_GAIN = Vector2.new(0.75, 1) * 8
local FOV_GAIN = 300
local ROLL_GAIN = -pi / 2

local PITCH_LIMIT = rad(90)

local VEL_STIFFNESS = 1.5
local PAN_STIFFNESS = 1.0
local FOV_STIFFNESS = 4.0
local ROLL_STIFFNESS = 1.0

local VEL_ADJ_STIFFNESS = 0.75
local PAN_ADJ_STIFFNESS = 0.75
local FOV_ADJ_STIFFNESS = 0.75
local ROLL_ADJ_STIFFNESS = 0.75

local VEL_MIN_STIFFNESS = 0.01
local PAN_MIN_STIFFNESS = 0.01
local FOV_MIN_STIFFNESS = 0.01
local ROLL_MIN_STIFFNESS = 0.01

local VEL_MAX_STIFFNESS = 10.0
local PAN_MAX_STIFFNESS = 10.0
local FOV_MAX_STIFFNESS = 10.0
local ROLL_MAX_STIFFNESS = 10.0

local lastPressTime = {}
local lastResetTime = 0
local DOUBLE_TAP_TIME_THRESHOLD = 0.25
local DOUBLE_TAP_DEBOUNCE_TIME = 0.1

local postEffects = {}
------------------------------------------------------------------------

local Spring = {}
do
	Spring.__index = Spring

	function Spring.new(freq, pos)
		local self = setmetatable({}, Spring)
		self.f = freq
		self.p = pos
		self.v = pos * 0
		return self
	end

	function Spring:Update(dt, goal)
		local f = self.f * 2 * pi
		local p0 = self.p
		local v0 = self.v

		local offset = goal - p0
		local decay = exp(-f * dt)

		local p1 = goal + (v0 * dt - offset * (f * dt + 1)) * decay
		local v1 = (f * dt * (offset * f - v0) + v0) * decay

		self.p = p1
		self.v = v1

		return p1
	end

	function Spring:SetFreq(freq)
		self.f = freq
	end

	function Spring:Reset(pos)
		self.p = pos
		self.v = pos * 0
	end
end

------------------------------------------------------------------------

local cameraPos = Vector3.new()
local cameraRot
if FFlagUserFreecamTiltControl then
	cameraRot = Vector3.new()
else
	cameraRot = Vector2.new()
end
local cameraFov = 0

local velSpring = Spring.new(VEL_STIFFNESS, Vector3.new())
local panSpring = Spring.new(PAN_STIFFNESS, Vector2.new())
local fovSpring = Spring.new(FOV_STIFFNESS, 0)
local rollSpring = Spring.new(ROLL_STIFFNESS, 0)

------------------------------------------------------------------------

local Input = {}
do
	local thumbstickCurve
	do
		local K_CURVATURE = 2.0
		local K_DEADZONE = 0.15

		local function fCurve(x)
			return (exp(K_CURVATURE * x) - 1) / (exp(K_CURVATURE) - 1)
		end

		local function fDeadzone(x)
			return fCurve((x - K_DEADZONE) / (1 - K_DEADZONE))
		end

		function thumbstickCurve(x)
			return sign(x) * clamp(fDeadzone(abs(x)), 0, 1)
		end
	end

	local gamepad = {
		ButtonX = 0,
		ButtonY = 0,
		DPadDown = 0,
		DPadUp = 0,
		DPadLeft = 0,
		DPadRight = 0,
		ButtonL2 = 0,
		ButtonR2 = 0,
		ButtonL1 = 0,
		ButtonR1 = 0,
		Thumbstick1 = Vector2.new(),
		Thumbstick2 = Vector2.new(),
	}

	local keyboard = {
		W = 0,
		A = 0,
		S = 0,
		D = 0,
		E = 0,
		Q = 0,
		U = 0,
		H = 0,
		J = 0,
		K = 0,
		I = 0,
		Y = 0,
		Up = 0,
		Down = 0,
		Left = 0,
		Right = 0,
		LeftShift = 0,
		RightShift = 0,
		Z = 0,
		C = 0,
		Comma = 0,
		Period = 0,
		LeftBracket = 0,
		RightBracket = 0,
		Semicolon = 0,
		Quote = 0,
		V = 0,
		B = 0,
		N = 0,
		M = 0,
		BackSlash = 0,
		Minus = 0,
		Equals = 0,
	}

	local mouse = {
		Delta = Vector2.new(),
		MouseWheel = 0,
	}

	local DEFAULT_FPS = 60
	local NAV_GAMEPAD_SPEED = Vector3.new(1, 1, 1)
	local NAV_KEYBOARD_SPEED = Vector3.new(1, 1, 1)
	local PAN_MOUSE_SPEED = Vector2.new(1, 1) * (pi / 64)
	local PAN_MOUSE_SPEED_DT = PAN_MOUSE_SPEED / DEFAULT_FPS
	local PAN_GAMEPAD_SPEED = Vector2.new(1, 1) * (pi / 8)
	local FOV_WHEEL_SPEED = 1.0
	local FOV_WHEEL_SPEED_DT = FOV_WHEEL_SPEED / DEFAULT_FPS
	local FOV_GAMEPAD_SPEED = 0.25
	local ROLL_GAMEPAD_SPEED = 1.0
	local ROLL_KEYBOARD_SPEED = 1.0
	local NAV_ADJ_SPEED = 0.75
	local NAV_MIN_SPEED = 0.01
	local NAV_MAX_SPEED = 4.0
	local NAV_SHIFT_MUL = 0.25
	local FOV_ADJ_SPEED = 0.75
	local FOV_MIN_SPEED = 0.01
	local FOV_MAX_SPEED = 4.0
	local ROLL_ADJ_SPEED = 0.75
	local ROLL_MIN_SPEED = 0.01
	local ROLL_MAX_SPEED = 4.0
	local DoFConstants = {
		FarIntensity = {
			ADJ = 0.1,
			MIN = 0.0,
			MAX = 1.0,
		},
		NearIntensity = {
			ADJ = 0.1,
			MIN = 0.0,
			MAX = 1.0,
		},
		FocusDistance = {
			ADJ = 20.0,
			MIN = 0.0,
			MAX = 200.0,
		},
		FocusRadius = {
			ADJ = 5.0,
			MIN = 0.0,
			MAX = 50.0,
		},
	}

	local navSpeed = 1
	local rollSpeed = 1
	local fovSpeed = 1

	function Input.Vel(dt)
		if FFlagUserFreecamControlSpeed then
			navSpeed = clamp(
				navSpeed + dt * (keyboard.Up - keyboard.Down + gamepad.DPadUp - gamepad.DPadDown) * NAV_ADJ_SPEED,
				NAV_MIN_SPEED,
				NAV_MAX_SPEED
			)
		else
			navSpeed = clamp(navSpeed + dt * (keyboard.Up - keyboard.Down) * NAV_ADJ_SPEED, 0.01, 4)
		end
		local kGamepad = Vector3.new(
			thumbstickCurve(gamepad.Thumbstick1.X),
			thumbstickCurve(gamepad.ButtonR2) - thumbstickCurve(gamepad.ButtonL2),
			thumbstickCurve(-gamepad.Thumbstick1.Y)
		) * NAV_GAMEPAD_SPEED

		local kKeyboard = Vector3.new(
			keyboard.D - keyboard.A + keyboard.K - keyboard.H,
			keyboard.E - keyboard.Q + keyboard.I - keyboard.Y,
			keyboard.S - keyboard.W + keyboard.J - keyboard.U
		) * NAV_KEYBOARD_SPEED

		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		return (kGamepad + kKeyboard) * (navSpeed * (shift and NAV_SHIFT_MUL or 1))
	end

	function Input.Pan(dt)
		local kGamepad = Vector2.new(thumbstickCurve(gamepad.Thumbstick2.Y), thumbstickCurve(-gamepad.Thumbstick2.X))
			* PAN_GAMEPAD_SPEED
		local kMouse = mouse.Delta * PAN_MOUSE_SPEED
		if FFlagUserFixFreecamDeltaTimeCalculation then
			if dt > 0 then
				kMouse = (mouse.Delta / dt) * PAN_MOUSE_SPEED_DT
			end
		end
		mouse.Delta = Vector2.new()
		return kGamepad + kMouse
	end

	function Input.Fov(dt)
		if FFlagUserFreecamControlSpeed then
			fovSpeed = clamp(
				fovSpeed + dt * (keyboard.Right - keyboard.Left + gamepad.DPadRight - gamepad.DPadLeft) * FOV_ADJ_SPEED,
				FOV_MIN_SPEED,
				FOV_MAX_SPEED
			)
		end
		local kGamepad = (gamepad.ButtonX - gamepad.ButtonY) * FOV_GAMEPAD_SPEED
		local kMouse = mouse.MouseWheel * FOV_WHEEL_SPEED
		if FFlagUserFixFreecamDeltaTimeCalculation then
			if dt > 0 then
				kMouse = (mouse.MouseWheel / dt) * FOV_WHEEL_SPEED_DT
			end
		end
		mouse.MouseWheel = 0
		if FFlagUserFreecamControlSpeed then
			return (kGamepad + kMouse) * fovSpeed
		else
			return kGamepad + kMouse
		end
	end

	function Input.Roll(dt)
		rollSpeed =
			clamp(rollSpeed + dt * (keyboard.Period - keyboard.Comma) * ROLL_ADJ_SPEED, ROLL_MIN_SPEED, ROLL_MAX_SPEED)

		local kGamepad = (gamepad.ButtonR1 - gamepad.ButtonL1) * ROLL_GAMEPAD_SPEED
		local kKeyboard = (keyboard.C - keyboard.Z) * ROLL_KEYBOARD_SPEED

		return (kGamepad + kKeyboard) * rollSpeed
	end

	function Input.SpringControl(dt)
		if FFlagUserFreecamDepthOfFieldEffect then
			local shiftIsDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			local ctrlIsDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)

			if shiftIsDown or ctrlIsDown then
				return -- reserve Shift+Keybinds for other actions, in this case Shift+Brackets for Depth of Field controls
			end
		end

		VEL_STIFFNESS = clamp(
			VEL_STIFFNESS + dt * (keyboard.RightBracket - keyboard.LeftBracket) * VEL_ADJ_STIFFNESS,
			VEL_MIN_STIFFNESS,
			VEL_MAX_STIFFNESS
		)
		velSpring:SetFreq(VEL_STIFFNESS)

		PAN_STIFFNESS = clamp(
			PAN_STIFFNESS + dt * (keyboard.Quote - keyboard.Semicolon) * PAN_ADJ_STIFFNESS,
			PAN_MIN_STIFFNESS,
			PAN_MAX_STIFFNESS
		)
		panSpring:SetFreq(PAN_STIFFNESS)

		FOV_STIFFNESS = clamp(
			FOV_STIFFNESS + dt * (keyboard.B - keyboard.V) * FOV_ADJ_STIFFNESS,
			FOV_MIN_STIFFNESS,
			FOV_MAX_STIFFNESS
		)
		fovSpring:SetFreq(FOV_STIFFNESS)

		ROLL_STIFFNESS = clamp(
			ROLL_STIFFNESS + dt * (keyboard.M - keyboard.N) * ROLL_ADJ_STIFFNESS,
			ROLL_MIN_STIFFNESS,
			ROLL_MAX_STIFFNESS
		)
		rollSpring:SetFreq(ROLL_STIFFNESS)
	end

	function Input.DoF(dt)
		local shiftIsDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local ctrlIsDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)

		if shiftIsDown then
			FreecamDepthOfField.FarIntensity = clamp(
				FreecamDepthOfField.FarIntensity
					+ dt * (keyboard.RightBracket - keyboard.LeftBracket) * DoFConstants.FarIntensity.ADJ,
				DoFConstants.FarIntensity.MIN,
				DoFConstants.FarIntensity.MAX
			)
			FreecamDepthOfField.InFocusRadius = clamp(
				FreecamDepthOfField.InFocusRadius
					+ dt * (keyboard.Equals - keyboard.Minus) * DoFConstants.FocusRadius.ADJ,
				DoFConstants.FocusRadius.MIN,
				DoFConstants.FocusRadius.MAX
			)
		elseif ctrlIsDown then
			FreecamDepthOfField.NearIntensity = clamp(
				FreecamDepthOfField.NearIntensity
					+ dt * (keyboard.RightBracket - keyboard.LeftBracket) * DoFConstants.NearIntensity.ADJ,
				DoFConstants.NearIntensity.MIN,
				DoFConstants.NearIntensity.MAX
			)
		else
			FreecamDepthOfField.FocusDistance = clamp(
				FreecamDepthOfField.FocusDistance
					+ dt * (keyboard.Equals - keyboard.Minus) * DoFConstants.FocusDistance.ADJ,
				DoFConstants.FocusDistance.MIN,
				DoFConstants.FocusDistance.MAX
			)
		end
	end

	do
		local function resetKeys(keys, table)
			for keyEnum, _ in pairs(keys) do
				if table[keyEnum.Name] then
					table[keyEnum.Name] = 0
				end
			end
		end

		local function handleDoubleTapReset(keyCode)
			local currentTime = os.clock()

			local previousPressTime = lastPressTime[keyCode]
			local timeSinceLastPress = previousPressTime and (currentTime - previousPressTime) or -1

			if previousPressTime and (timeSinceLastPress <= DOUBLE_TAP_TIME_THRESHOLD) then
				if (currentTime - lastResetTime) >= DOUBLE_TAP_DEBOUNCE_TIME then
					cameraRot = Vector3.new(cameraRot.x, cameraRot.y, 0)
					rollSpring:Reset(0)
					if FFlagUserFreecamDepthOfFieldEffect then
						resetKeys(FREECAM_TILT_RESET_GP, gamepad)
						resetKeys(FREECAM_TILT_RESET_KB, keyboard)
					else
						gamepad.ButtonL1 = 0
						gamepad.ButtonR1 = 0
						keyboard.C = 0
						keyboard.Z = 0
					end
					lastResetTime = currentTime
				end
			end
			lastPressTime[keyCode] = currentTime
		end

		local function Keypress(action, state, input)
			keyboard[input.KeyCode.Name] = state == Enum.UserInputState.Begin and 1 or 0

			if FFlagUserFreecamTiltControl then
				if FREECAM_TILT_RESET_KB[input.KeyCode] and input.UserInputState == Enum.UserInputState.Begin then
					handleDoubleTapReset(input.KeyCode)
				end
			end

			if FFlagUserFreecamDepthOfFieldEffect then
				if FREECAM_DOF_TOGGLE[input.KeyCode] and input.UserInputState == Enum.UserInputState.Begin then
					if not FreecamDepthOfField.Enabled then
						postEffects = {}
						-- Disable all existing DepthOfFieldEffects to be controlled by custom Freecam DoF.
						for _, effect in ipairs(Camera:GetChildren()) do
							if effect:IsA("DepthOfFieldEffect") and effect.Enabled then
								postEffects[#postEffects + 1] = effect
								effect.Enabled = false
							end
						end
						for _, effect in ipairs(Lighting:GetChildren()) do
							if effect:IsA("DepthOfFieldEffect") and effect.Enabled then
								postEffects[#postEffects + 1] = effect
								effect.Enabled = false
							end
						end
						Camera.ChildAdded:Connect(function(child)
							if child:IsA("DepthOfFieldEffect") and child.Enabled then
								postEffects[#postEffects + 1] = child
								child.Enabled = false
							end
						end)
						Lighting.ChildAdded:Connect(function(child)
							if child:IsA("DepthOfFieldEffect") and child.Enabled then
								postEffects[#postEffects + 1] = child
								child.Enabled = false
							end
						end)
					else
						-- Re-enable all existing DepthOfFieldEffects when custom Freecam DoF is off.
						for _, effect in ipairs(postEffects) do
							if effect.Parent then
								effect.Enabled = true
							end
						end
						postEffects = {}
					end
					FreecamDepthOfField.Enabled = not FreecamDepthOfField.Enabled
					resetKeys(FREECAM_DOF_TOGGLE, keyboard)
				end
			end

			return Enum.ContextActionResult.Sink
		end

		local function GpButton(action, state, input)
			gamepad[input.KeyCode.Name] = state == Enum.UserInputState.Begin and 1 or 0

			if FFlagUserFreecamTiltControl then
				if FREECAM_TILT_RESET_GP[input.KeyCode] and input.UserInputState == Enum.UserInputState.Begin then
					handleDoubleTapReset(input.KeyCode)
				end
			end

			return Enum.ContextActionResult.Sink
		end

		local function MousePan(action, state, input)
			local delta = input.Delta
			mouse.Delta = Vector2.new(-delta.y, -delta.x)
			return Enum.ContextActionResult.Sink
		end

		local function Thumb(action, state, input)
			gamepad[input.KeyCode.Name] = input.Position
			return Enum.ContextActionResult.Sink
		end

		local function Trigger(action, state, input)
			gamepad[input.KeyCode.Name] = input.Position.z
			return Enum.ContextActionResult.Sink
		end

		local function MouseWheel(action, state, input)
			mouse[input.UserInputType.Name] = -input.Position.z
			return Enum.ContextActionResult.Sink
		end

		local function Zero(t)
			for k, v in pairs(t) do
				t[k] = v * 0
			end
		end

		function Input.StartCapture()
			if FFlagUserFreecamControlSpeed then
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboard",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.W,
					Enum.KeyCode.U,
					Enum.KeyCode.A,
					Enum.KeyCode.H,
					Enum.KeyCode.S,
					Enum.KeyCode.J,
					Enum.KeyCode.D,
					Enum.KeyCode.K,
					Enum.KeyCode.E,
					Enum.KeyCode.I,
					Enum.KeyCode.Q,
					Enum.KeyCode.Y
				)
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboardControlSpeed",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.Up,
					Enum.KeyCode.Down,
					Enum.KeyCode.Left,
					Enum.KeyCode.Right
				)
				ContextActionService:BindActionAtPriority(
					"FreecamGamepadControlSpeed",
					GpButton,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.DPadUp,
					Enum.KeyCode.DPadDown,
					Enum.KeyCode.DPadRight
				)
			else
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboard",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.W,
					Enum.KeyCode.U,
					Enum.KeyCode.A,
					Enum.KeyCode.H,
					Enum.KeyCode.S,
					Enum.KeyCode.J,
					Enum.KeyCode.D,
					Enum.KeyCode.K,
					Enum.KeyCode.E,
					Enum.KeyCode.I,
					Enum.KeyCode.Q,
					Enum.KeyCode.Y,
					Enum.KeyCode.Up,
					Enum.KeyCode.Down
				)
			end
			if FFlagUserFreecamTiltControl then
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboardTiltControl",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.Z,
					Enum.KeyCode.C
				)
				ContextActionService:BindActionAtPriority(
					"FreecamGamepadTiltControl",
					GpButton,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.ButtonL1,
					Enum.KeyCode.ButtonR1
				)
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboardTiltControlSpeed",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.Comma,
					Enum.KeyCode.Period
				)
				if FFlagUserFreecamSmoothnessControl then
					ContextActionService:BindActionAtPriority(
						"FreecamKeyboardSmoothnessControl",
						Keypress,
						false,
						INPUT_PRIORITY,
						Enum.KeyCode.LeftBracket,
						Enum.KeyCode.RightBracket,
						Enum.KeyCode.Semicolon,
						Enum.KeyCode.Quote,
						Enum.KeyCode.V,
						Enum.KeyCode.B,
						Enum.KeyCode.N,
						Enum.KeyCode.M
					)
				end
			end
			if FFlagUserFreecamDepthOfFieldEffect then
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboardDoFToggle",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.BackSlash
				)
				ContextActionService:BindActionAtPriority(
					"FreecamKeyboardDoFControls",
					Keypress,
					false,
					INPUT_PRIORITY,
					Enum.KeyCode.Minus,
					Enum.KeyCode.Equals
				)
			end
			ContextActionService:BindActionAtPriority(
				"FreecamMousePan",
				MousePan,
				false,
				INPUT_PRIORITY,
				Enum.UserInputType.MouseMovement
			)
			ContextActionService:BindActionAtPriority(
				"FreecamMouseWheel",
				MouseWheel,
				false,
				INPUT_PRIORITY,
				Enum.UserInputType.MouseWheel
			)
			ContextActionService:BindActionAtPriority(
				"FreecamGamepadButton",
				GpButton,
				false,
				INPUT_PRIORITY,
				Enum.KeyCode.ButtonX,
				Enum.KeyCode.ButtonY
			)
			ContextActionService:BindActionAtPriority(
				"FreecamGamepadTrigger",
				Trigger,
				false,
				INPUT_PRIORITY,
				Enum.KeyCode.ButtonR2,
				Enum.KeyCode.ButtonL2
			)
			ContextActionService:BindActionAtPriority(
				"FreecamGamepadThumbstick",
				Thumb,
				false,
				INPUT_PRIORITY,
				Enum.KeyCode.Thumbstick1,
				Enum.KeyCode.Thumbstick2
			)
		end

		function Input.StopCapture()
			navSpeed = 1
			if FFlagUserFreecamControlSpeed then
				fovSpeed = 1
			end
			if FFlagUserFreecamTiltControl then
				rollSpeed = 1
			end
			Zero(gamepad)
			Zero(keyboard)
			Zero(mouse)
			ContextActionService:UnbindAction("FreecamKeyboard")
			if FFlagUserFreecamControlSpeed then
				ContextActionService:UnbindAction("FreecamKeyboardControlSpeed")
				ContextActionService:UnbindAction("FreecamGamepadControlSpeed")
			end
			if FFlagUserFreecamTiltControl then
				ContextActionService:UnbindAction("FreecamKeyboardTiltControl")
				ContextActionService:UnbindAction("FreecamGamepadTiltControl")
				ContextActionService:UnbindAction("FreecamKeyboardTiltControlSpeed")
				if FFlagUserFreecamSmoothnessControl then
					ContextActionService:UnbindAction("FreecamKeyboardSmoothnessControl")
				end
			end
			if FFlagUserFreecamDepthOfFieldEffect then
				ContextActionService:UnbindAction("FreecamKeyboardDoFToggle")
				ContextActionService:UnbindAction("FreecamKeyboardDoFControls")
			end
			ContextActionService:UnbindAction("FreecamMousePan")
			ContextActionService:UnbindAction("FreecamMouseWheel")
			ContextActionService:UnbindAction("FreecamGamepadButton")
			ContextActionService:UnbindAction("FreecamGamepadTrigger")
			ContextActionService:UnbindAction("FreecamGamepadThumbstick")
		end
	end
end

------------------------------------------------------------------------

local function StepFreecam(dt)
	if FFlagUserFreecamSmoothnessControl then
		Input.SpringControl(dt)
	end

	if FFlagUserFreecamDepthOfFieldEffect then
		if FreecamDepthOfField and FreecamDepthOfField.Parent then
			Input.DoF(dt)
		end
	end

	local vel = velSpring:Update(dt, Input.Vel(dt))
	local pan = panSpring:Update(dt, Input.Pan(dt))
	local fov = fovSpring:Update(dt, Input.Fov(dt))
	local roll
	if FFlagUserFreecamTiltControl then
		roll = rollSpring:Update(dt, Input.Roll(dt))
	end

	local zoomFactor = sqrt(tan(rad(70 / 2)) / tan(rad(cameraFov / 2)))

	cameraFov = clamp(cameraFov + fov * FOV_GAIN * (dt / zoomFactor), 1, 120)
	local cameraCFrame
	if FFlagUserFreecamTiltControl then
		local panVector: Vector2 = pan * PAN_GAIN * (dt / zoomFactor)
		cameraRot = cameraRot + Vector3.new(panVector.X, panVector.Y, roll * ROLL_GAIN * (dt / zoomFactor))
		if FFlagUserFreecamSmoothnessControl then
			cameraRot = Vector3.new(cameraRot.x % (2 * pi), cameraRot.y % (2 * pi), cameraRot.z % (2 * pi))
		else
			cameraRot = Vector3.new(clamp(cameraRot.x, -PITCH_LIMIT, PITCH_LIMIT), cameraRot.y % (2 * pi), cameraRot.z)
		end

		cameraCFrame = CFrame.new(cameraPos)
			* CFrame.fromOrientation(cameraRot.x, cameraRot.y, cameraRot.z)
			* CFrame.new(vel * NAV_GAIN * dt)
	else
		cameraRot = cameraRot + pan * PAN_GAIN * (dt / zoomFactor)
		cameraRot = Vector2.new(clamp(cameraRot.x, -PITCH_LIMIT, PITCH_LIMIT), cameraRot.y % (2 * pi))

		cameraCFrame = CFrame.new(cameraPos)
			* CFrame.fromOrientation(cameraRot.x, cameraRot.y, 0)
			* CFrame.new(vel * NAV_GAIN * dt)
	end

	cameraPos = cameraCFrame.p

	Camera.CFrame = cameraCFrame
	Camera.Focus = cameraCFrame
	Camera.FieldOfView = cameraFov
end

local function CheckMouseLockAvailability()
	local devAllowsMouseLock = Players.LocalPlayer.DevEnableMouseLock
	local devMovementModeIsScriptable = Players.LocalPlayer.DevComputerMovementMode
		== Enum.DevComputerMovementMode.Scriptable
	local userHasMouseLockModeEnabled = GameSettings.ControlMode == Enum.ControlMode.MouseLockSwitch
	local userHasClickToMoveEnabled = GameSettings.ComputerMovementMode == Enum.ComputerMovementMode.ClickToMove
	local MouseLockAvailable = devAllowsMouseLock
		and userHasMouseLockModeEnabled
		and not userHasClickToMoveEnabled
		and not devMovementModeIsScriptable

	return MouseLockAvailable
end

------------------------------------------------------------------------

local PlayerState = {}
do
	local mouseBehavior
	local mouseIconEnabled
	local cameraType
	local cameraFocus
	local cameraCFrame
	local cameraFieldOfView
	local screenGuis = {}
	local gscriptsGuis = {}
	local coreGuis = {
		Backpack = true,
		Chat = true,
		Health = true,
		PlayerList = true,
	}
	local setCores = {
		BadgesNotificationsActive = true,
		PointsNotificationsActive = true,
	}

	-- Save state and set up for freecam
	function PlayerState.Push()
		for name in pairs(coreGuis) do
			coreGuis[name] = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType[name])
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType[name], false)
		end
		for name in pairs(setCores) do
			setCores[name] = StarterGui:GetCore(name)
			StarterGui:SetCore(name, false)
		end
		local playergui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playergui then
			for _, gui in pairs(playergui:GetChildren()) do
				if gui:IsA("ScreenGui") and gui.Enabled then
					screenGuis[#screenGuis + 1] = gui
					gui.Enabled = false
				end
			end
			if FFlagUserFixFreecamGuiChangeVisibility then
				playergui.ChildAdded:Connect(function(child)
					if child:IsA("ScreenGui") and child.Enabled then
						screenGuis[#screenGuis + 1] = child
						child.Enabled = false
					end
				end)
			end
		end

		local coreGui = game:GetService("CoreGui")
		local gscriptsFolder = coreGui:FindFirstChild("GScripts")
		if gscriptsFolder then
			for _, gui in pairs(gscriptsFolder:GetChildren()) do
				if gui:IsA("ScreenGui") then
					gscriptsGuis[gui] = gui.Enabled
					gui.Enabled = false
				end
			end
		end

		cameraFieldOfView = Camera.FieldOfView
		Camera.FieldOfView = 70

		cameraType = Camera.CameraType
		Camera.CameraType = Enum.CameraType.Custom

		cameraCFrame = Camera.CFrame
		cameraFocus = Camera.Focus

		mouseIconEnabled = UserInputService.MouseIconEnabled
		UserInputService.MouseIconEnabled = false

		if FFlagUserExitFreecamBreaksWithShiftlock and CheckMouseLockAvailability() then
			mouseBehavior = Enum.MouseBehavior.Default
		else
			mouseBehavior = UserInputService.MouseBehavior
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	-- Restore state
	function PlayerState.Pop()
		for name, isEnabled in pairs(coreGuis) do
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType[name], isEnabled)
		end
		for name, isEnabled in pairs(setCores) do
			StarterGui:SetCore(name, isEnabled)
		end
		for _, gui in pairs(screenGuis) do
			if gui.Parent then
				gui.Enabled = true
			end
		end
		if FFlagUserFixFreecamGuiChangeVisibility then
			screenGuis = {}
		end

		for gui, wasEnabled in pairs(gscriptsGuis) do
			if gui.Parent then
				gui.Enabled = wasEnabled
			end
		end
		gscriptsGuis = {}

		Camera.FieldOfView = cameraFieldOfView
		cameraFieldOfView = nil

		Camera.CameraType = cameraType
		cameraType = nil

		Camera.CFrame = cameraCFrame
		cameraCFrame = nil

		Camera.Focus = cameraFocus
		cameraFocus = nil

		UserInputService.MouseIconEnabled = mouseIconEnabled
		mouseIconEnabled = nil

		UserInputService.MouseBehavior = mouseBehavior
		mouseBehavior = nil
	end
end

local function StartFreecam()
	if not FFlagUserFreecamGuiDestabilization then
		if FFlagUserShowGuiHideToggles then
			script:SetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME, true)
		end
	end

	local cameraCFrame = Camera.CFrame
	if FFlagUserFreecamTiltControl then
		cameraRot = Vector3.new(cameraCFrame:toEulerAnglesYXZ())
	else
		cameraRot = Vector2.new(cameraCFrame:toEulerAnglesYXZ())
	end
	cameraPos = cameraCFrame.p
	cameraFov = Camera.FieldOfView

	velSpring:Reset(Vector3.new())
	panSpring:Reset(Vector2.new())
	fovSpring:Reset(0)
	if FFlagUserFreecamTiltControl then
		rollSpring:Reset(0)
	end

	if FFlagUserFreecamSmoothnessControl then
		VEL_STIFFNESS = 1.5
		PAN_STIFFNESS = 1.0
		FOV_STIFFNESS = 4.0
		ROLL_STIFFNESS = 1.0
	end

	PlayerState.Push()

	if FFlagUserFreecamDepthOfFieldEffect then
		if not FreecamDepthOfField or not FreecamDepthOfField.Parent then
			FreecamDepthOfField = Instance.new("DepthOfFieldEffect")
			FreecamDepthOfField.Enabled = false
			FreecamDepthOfField.Name = "FreecamDepthOfField"
			FreecamDepthOfField.Parent = Camera
		end
	end

	RunService:BindToRenderStep("Freecam", Enum.RenderPriority.Camera.Value, StepFreecam)
	Input.StartCapture()
end

local function StopFreecam()
	if not FFlagUserFreecamGuiDestabilization then
		if FFlagUserShowGuiHideToggles then
			script:SetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME, false)
		end
	end

	if FFlagUserFreecamDepthOfFieldEffect then
		if FreecamDepthOfField and FreecamDepthOfField.Parent then
			if FreecamDepthOfField.Enabled then
				for _, effect in ipairs(postEffects) do
					if effect.Parent then
						effect.Enabled = true
					end
				end
				postEffects = {}
			end
			FreecamDepthOfField.Enabled = false
		end
	end

	Input.StopCapture()
	RunService:UnbindFromRenderStep("Freecam")
	PlayerState.Pop()
end

------------------------------------------------------------------------

do
	local enabled = false
	local attributeConnection = nil
	local guiEnabled = false

	-- Load persisted keybinds (falls back to defaults if file I/O unavailable)
	local loadedConfig = Config.Load()
	do
		local macroArr = KeybindStringToArray(loadedConfig.FreecamKeybind)
		if macroArr then
			FREECAM_MACRO_KB = macroArr
		end
		local guiArr = KeybindStringToArray(loadedConfig.GuiKeybind)
		if guiArr then
			GUI_TOGGLE_KB = guiArr
		end
	end

	local function SaveKeybinds()
		Config.Save({
			GuiKeybind = KeybindArrayToString(GUI_TOGGLE_KB),
			FreecamKeybind = KeybindArrayToString(FREECAM_MACRO_KB),
		})
	end

	local function ToggleFreecam()
		if enabled then
			StopFreecam()
		else
			StartFreecam()
		end
		enabled = not enabled
		if FFlagUserFreecamGuiDestabilization then
			script:SetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME, enabled)
		end
	end

	local function CheckMacro(macro)
		for i = 1, #macro - 1 do
			if not UserInputService:IsKeyDown(macro[i]) then
				return
			end
		end
		ToggleFreecam()
	end

	-- Forward declared so GUI toggle function can be referenced before defined
	local ToggleGui

	local function HandleActivationInput(action, state, input)
		if state == Enum.UserInputState.Begin then
			if input.KeyCode == FREECAM_MACRO_KB[#FREECAM_MACRO_KB] then
				CheckMacro(FREECAM_MACRO_KB)
			end

			if input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.DPadLeft then
				ToggleFreecam()
			end
		end

		return Enum.ContextActionResult.Pass
	end

	local function HandleGuiToggleInput(action, state, input)
		if state == Enum.UserInputState.Begin then
			if input.KeyCode == GUI_TOGGLE_KB[#GUI_TOGGLE_KB] then
				local isMacro = #GUI_TOGGLE_KB > 1
				if isMacro then
					for i = 1, #GUI_TOGGLE_KB - 1 do
						if not UserInputService:IsKeyDown(GUI_TOGGLE_KB[i]) then
							return Enum.ContextActionResult.Pass
						end
					end
				end
				if ToggleGui then
					ToggleGui()
				end
			end
		end
		return Enum.ContextActionResult.Pass
	end

	local function RebindFreecamAction()
		ContextActionService:UnbindAction("FreecamToggle")
		ContextActionService:BindActionAtPriority(
			"FreecamToggle",
			HandleActivationInput,
			false,
			TOGGLE_INPUT_PRIORITY,
			FREECAM_MACRO_KB[#FREECAM_MACRO_KB]
		)
	end

	local function RebindGuiAction()
		ContextActionService:UnbindAction("FreecamGuiToggle")
		ContextActionService:BindActionAtPriority(
			"FreecamGuiToggle",
			HandleGuiToggleInput,
			false,
			TOGGLE_INPUT_PRIORITY,
			GUI_TOGGLE_KB[#GUI_TOGGLE_KB]
		)
	end

	RebindFreecamAction()
	RebindGuiAction()

	ContextActionService:BindActionAtPriority("FreecamToggleDPAD", HandleActivationInput, false, TOGGLE_INPUT_PRIORITY, Enum.KeyCode.DPadLeft)

	if FFlagUserFreecamGuiDestabilization or FFlagUserShowGuiHideToggles then
		script:SetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME, enabled)
		attributeConnection = script:GetAttributeChangedSignal(FREECAM_ENABLED_ATTRIBUTE_NAME):Connect(function()
			local attributeValue = script:GetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME)

			if typeof(attributeValue) ~= "boolean" then
				script:SetAttribute(FREECAM_ENABLED_ATTRIBUTE_NAME, enabled)
				return
			end

			-- If the attribute's value and `enabled` var don't match, pick attribute value as
			-- source of truth
			if attributeValue ~= enabled then
				if attributeValue then
					StartFreecam()
					enabled = true
				else
					StopFreecam()
					enabled = false
				end
			end
		end)
	end

	------------------------------------------------------------------------
	-- Simple GUI: toggle (P key) with two rebind buttons for the GUI
	-- keybind itself and the freecam keybind. Listens for the next key
	-- press after a rebind button is clicked, then saves to JSON.
	------------------------------------------------------------------------

	local screenGui = nil
	local rebindListening = nil -- "gui" | "freecam" | nil
	local rebindConnection = nil
	local guiKeyLabel, freecamKeyLabel
	local guiRebindButton, freecamRebindButton

	local function BuildGui()
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "FreecamConfigGui"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = true
		screenGui.DisplayOrder = 1000
		screenGui.Enabled = false
		screenGui.Parent = LocalPlayer:FindFirstChildOfClass("PlayerGui") or game:GetService("CoreGui")

		local frame = Instance.new("Frame")
		frame.Name = "MainFrame"
		frame.Size = UDim2.new(0, 260, 0, 150)
		frame.Position = UDim2.new(0, 20, 0.5, -75)
		frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		frame.BorderSizePixel = 0
		frame.Active = true
		frame.Draggable = true
		frame.Parent = screenGui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.new(1, 0, 0, 30)
		title.BackgroundTransparency = 1
		title.Text = "Freecam Settings"
		title.TextColor3 = Color3.fromRGB(255, 255, 255)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 16
		title.Parent = frame

		local function MakeRow(yOffset, labelText)
			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -20, 0, 40)
			row.Position = UDim2.new(0, 10, 0, yOffset)
			row.BackgroundTransparency = 1
			row.Parent = frame

			local label = Instance.new("TextLabel")
			label.Size = UDim2.new(0.5, 0, 1, 0)
			label.BackgroundTransparency = 1
			label.Text = labelText
			label.TextColor3 = Color3.fromRGB(220, 220, 220)
			label.Font = Enum.Font.Gotham
			label.TextSize = 13
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Parent = row

			local button = Instance.new("TextButton")
			button.Size = UDim2.new(0.5, -5, 1, -8)
			button.Position = UDim2.new(0.5, 5, 0, 4)
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
			button.TextColor3 = Color3.fromRGB(255, 255, 255)
			button.Font = Enum.Font.Gotham
			button.TextSize = 12
			button.AutoButtonColor = true
			button.Parent = row

			local btnCorner = Instance.new("UICorner")
			btnCorner.CornerRadius = UDim.new(0, 6)
			btnCorner.Parent = button

			return button
		end

		guiRebindButton = MakeRow(40, "Toggle GUI:")
		freecamRebindButton = MakeRow(85, "Toggle Freecam:")
		guiKeyLabel = guiRebindButton
		freecamKeyLabel = freecamRebindButton

		local hint = Instance.new("TextLabel")
		hint.Size = UDim2.new(1, -20, 0, 20)
		hint.Position = UDim2.new(0, 10, 0, 125)
		hint.BackgroundTransparency = 1
		hint.Text = "Click a button, then press a key"
		hint.TextColor3 = Color3.fromRGB(150, 150, 150)
		hint.Font = Enum.Font.Gotham
		hint.TextSize = 11
		hint.Parent = frame

		local function RefreshLabels()
			guiRebindButton.Text = KeybindArrayToString(GUI_TOGGLE_KB)
			freecamRebindButton.Text = KeybindArrayToString(FREECAM_MACRO_KB)
		end
		RefreshLabels()

		local function StartListening(which, button)
			if rebindConnection then
				rebindConnection:Disconnect()
				rebindConnection = nil
			end
			rebindListening = which
			button.Text = "Press a key..."

			rebindConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
				if input.UserInputType ~= Enum.UserInputType.Keyboard then
					return
				end
				local keyCode = input.KeyCode
				if keyCode == Enum.KeyCode.Unknown then
					return
				end

				local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
					or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

				local newBind
				if shiftHeld and keyCode ~= Enum.KeyCode.LeftShift and keyCode ~= Enum.KeyCode.RightShift then
					newBind = { Enum.KeyCode.LeftShift, keyCode }
				else
					newBind = { keyCode }
				end

				if which == "gui" then
					GUI_TOGGLE_KB = newBind
					RebindGuiAction()
				elseif which == "freecam" then
					FREECAM_MACRO_KB = newBind
					RebindFreecamAction()
				end

				SaveKeybinds()
				RefreshLabels()

				rebindListening = nil
				if rebindConnection then
					rebindConnection:Disconnect()
					rebindConnection = nil
				end
			end)
		end

		guiRebindButton.MouseButton1Click:Connect(function()
			StartListening("gui", guiRebindButton)
		end)
		freecamRebindButton.MouseButton1Click:Connect(function()
			StartListening("freecam", freecamRebindButton)
		end)
	end

	ToggleGui = function()
		if not screenGui then
			BuildGui()
		end
		guiEnabled = not guiEnabled
		screenGui.Enabled = guiEnabled
	end

	-- FULL STOP: tears down everything this script instance owns.
	-- Called either by this instance unbinding itself, or by a newer
	-- duplicate instance forcing this one to die.
	local stopped = false
	local function FullStop()
		if stopped then
			return
		end
		stopped = true

		if enabled then
			StopFreecam()
			enabled = false
		end

		ContextActionService:UnbindAction("FreecamToggle")
		ContextActionService:UnbindAction("FreecamToggleDPAD")
		ContextActionService:UnbindAction("FreecamGuiToggle")

		if attributeConnection then
			attributeConnection:Disconnect()
			attributeConnection = nil
		end

		if rebindConnection then
			rebindConnection:Disconnect()
			rebindConnection = nil
		end

		if screenGui then
			screenGui:Destroy()
			screenGui = nil
		end
	end

	------------------------------------------------------------------------
	-- Duplicate-instance marker registration
	-- Lets a future duplicate run of this script find and fully stop this one.
	------------------------------------------------------------------------
	do
		local CoreGui = game:GetService("CoreGui")
		local MARKER_NAME = "__FreecamRunning_Marker"

		local killId = tostring(math.random(1, 1e9)) .. "_" .. tostring(os.clock())
		_G["__FreecamKill_" .. killId] = FullStop

		local marker = Instance.new("Folder")
		marker.Name = MARKER_NAME
		marker:SetAttribute("KillId", killId)
		marker.Parent = CoreGui

		-- If this marker instance is destroyed externally (e.g. CoreGui cleared),
		-- also clean up the dangling _G entry to avoid leaking references.
		marker.AncestryChanged:Connect(function(_, parent)
			if not parent then
				_G["__FreecamKill_" .. killId] = nil
			end
		end)
	end
end
