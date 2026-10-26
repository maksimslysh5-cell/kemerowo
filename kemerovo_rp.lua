--[[
	Кемерово РП | ПНЕВМО / БУСТЕР / Подвеска
	Для Delta Executor.

	Запуск (после заливки на GitHub, ссылка «Raw»):
	loadstring(game:HttpGet("https://raw.githubusercontent.com/ПОЛЬЗОВАТЕЛЬ/РЕПОЗИТОРИЙ/main/kemerovo_rp.lua"))()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

-- повторный запуск: убрать старое меню и вернуть родную подвеску
local env = (getgenv and getgenv()) or _G
if env.KRP_Cleanup then
	pcall(env.KRP_Cleanup)
end

------------------------------------------------------------------------
-- НАСТРОЙКИ (можно менять)
------------------------------------------------------------------------
local FONT = Enum.Font.SourceSansSemibold -- шрифт с кириллицей
local STUDS_TO_KMH = 1.008 -- студы/сек -> км/ч (если спидометр игры показывает иначе, подправь)
local TOP_ACCEL = 14 -- добавка при зажатом газе до предела скорости, студы/сек² (базовая сила)
local MAX_EXTRA = 160 -- потолок общей добавки, студы/сек²

local COLOR_BODY = Color3.fromRGB(138, 142, 150)
local COLOR_HEADER = Color3.fromRGB(116, 120, 128)
local COLOR_WHITE = Color3.fromRGB(255, 255, 255)
local COLOR_BLACK = Color3.fromRGB(0, 0, 0)
local COLOR_RED = Color3.fromRGB(255, 72, 72)
local STROKE_T = 0.55 -- прозрачность обводки текста (больше = тоньше)

------------------------------------------------------------------------
-- СОСТОЯНИЕ
------------------------------------------------------------------------
local state = {
	pneumo = false,
	boost = false,
	susp = false,
	height = 0, -- % к высоте пружин
	accel = 30, -- сила ускорения, 0-100
	top = 40, -- сила максимальной скорости, 0-100 (0 = выкл)
	stiff = 100, -- жёсткость, %
	damp = 100, -- демпфирование, %
}

local alive = true
local connections = {}
local car = nil
local ignoredSeat = nil

local function connect(signal, fn)
	local c = signal:Connect(fn)
	connections[#connections + 1] = c
	return c
end

------------------------------------------------------------------------
-- МАШИНА: поиск, пружины подвески
------------------------------------------------------------------------
local function currentSeat()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum and hum.SeatPart or nil
end

local function findCarModel(seat)
	local m = seat:FindFirstAncestorOfClass("Model")
	if not m then
		return nil
	end
	while true do
		local p = m.Parent
		if not p or p == workspace or not p:IsA("Model") then
			break
		end
		local seats = 0
		for _, d in ipairs(p:GetDescendants()) do
			if d:IsA("VehicleSeat") then
				seats = seats + 1
				if seats > 1 then
					break
				end
			end
		end
		if seats > 1 then
			break
		end
		m = p
	end
	return m
end

local function looksLikeCar(seat, model)
	if seat:IsA("VehicleSeat") then
		return true
	end
	return model:FindFirstChildWhichIsA("SpringConstraint", true) ~= nil
end

local function setLimits(sp, mn, mx)
	if mx >= sp.MaxLength then
		sp.MaxLength = mx
		sp.MinLength = mn
	else
		sp.MinLength = mn
		sp.MaxLength = mx
	end
end

local function restoreSprings(c)
	if not c then
		return
	end
	for sp, o in pairs(c.orig) do
		if sp.Parent then
			pcall(function()
				sp.FreeLength = o.Free
				if o.Lim then
					setLimits(sp, o.Min, o.Max)
				end
				sp.Stiffness = o.Stiff
				sp.Damping = o.Damp
			end)
		end
	end
	c.touched = false
end

local function refreshCar()
	local seat = currentSeat()
	if car and car.seat == seat then
		return
	end
	if car then
		restoreSprings(car)
		car = nil
	end
	if not seat then
		ignoredSeat = nil
		return
	end
	if seat == ignoredSeat then
		return
	end
	local model = findCarModel(seat)
	if not model or not looksLikeCar(seat, model) then
		ignoredSeat = seat
		return
	end
	local c = {
		seat = seat,
		model = model,
		orig = {},
		count = 0,
		h = 1,
		touched = false,
		gain = 0,
		pushedAt = 0,
		fwdSign = 1,
	}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("SpringConstraint") then
			c.orig[d] = {
				Free = d.FreeLength,
				Min = d.MinLength,
				Max = d.MaxLength,
				Lim = d.LimitsEnabled,
				Stiff = d.Stiffness,
				Damp = d.Damping,
			}
			c.count = c.count + 1
		end
	end
	local tv = model:FindFirstChild("Throttle", true)
	if tv and (tv:IsA("NumberValue") or tv:IsA("IntValue")) then
		c.throttleValue = tv
	end
	car = c
end

-- Пневмо (высота) + Подвеска (жёсткость / демпфирование)
local function updateSprings(dt)
	local c = car
	local targetH = state.pneumo and (1 + state.height / 100) or 1
	local sm = state.susp and state.stiff / 100 or 1
	local dm = state.susp and state.damp / 100 or 1

	c.h = c.h + (targetH - c.h) * (1 - math.exp(-7 * dt))
	if math.abs(c.h - targetH) < 0.002 then
		c.h = targetH
	end

	local modified = (c.h ~= 1) or (sm ~= 1) or (dm ~= 1)
	if not modified then
		if c.touched then
			restoreSprings(c)
		end
		return
	end

	c.touched = true
	for sp, o in pairs(c.orig) do
		if sp.Parent then
			pcall(function()
				sp.FreeLength = math.max(0.05, o.Free * c.h)
				if o.Lim then
					setLimits(sp, o.Min * c.h, o.Max * c.h)
				end
				sp.Stiffness = o.Stiff * sm
				sp.Damping = o.Damp * dm
			end)
		end
	end
end

------------------------------------------------------------------------
-- БУСТЕР
------------------------------------------------------------------------
-- Бустер:
-- 1) разгон: к набору скорости машины добавляем ещё (разгон% - 100%) от него;
-- 2) макс. скорость: пока газ зажат и скорость ниже предела, подталкиваем вперёд.
local function lookFlat(seat)
	local l = seat.CFrame.LookVector
	local f = Vector3.new(l.X, 0, l.Z)
	if f.Magnitude < 0.05 then
		return nil
	end
	return f.Unit
end

local function throttleHeld(c)
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if c.seat:IsA("VehicleSeat") and c.seat.ThrottleFloat > 0.1 then
		return true
	end
	if c.throttleValue and c.throttleValue.Parent and c.throttleValue.Value > 0.1 then
		return true
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up)
end

local function updateBoost(dt)
	local c = car
	local root = c.seat.AssemblyRootPart
	if not root or root.Anchored then
		c.expected = nil
		return
	end

	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude

	if c.expected == nil or dt > 0.1 then
		c.expected = speed
		c.gain = 0
		return
	end

	-- набор скорости машины без нашей добавки (студы/сек²), сглаженный
	local gainPerSec = (speed - c.expected) / math.max(dt, 1 / 240)
	c.gain = c.gain + (gainPerSec - c.gain) * math.min(1, dt * 12)
	c.expected = speed

	if not state.boost then
		return
	end

	local throttle = throttleHeld(c)
	local look = lookFlat(c.seat)
	local moveDir = speed > 0.5 and (flat / speed) or nil

	-- в какую сторону у этой машины «вперёд»
	if throttle and look and moveDir and c.gain > 3 and speed > 5 then
		local d = moveDir:Dot(look)
		if math.abs(d) > 0.5 then
			c.fwdSign = d > 0 and 1 or -1
		end
	end

	-- куда толкать
	local pushDir = nil
	if speed > 2 then
		pushDir = flat / speed
	elseif look then
		pushDir = look * c.fwdSign
	elseif moveDir then
		pushDir = moveDir
	end

	local extra = 0

	-- 1) быстрее разгон
	if moveDir then
		extra = (state.accel * 0.07) * math.max(0, c.gain - 0.5)
	end

	-- 2) выше максималка
	if throttle then
		local forwardOk = true
		if moveDir and look then
			forwardOk = moveDir:Dot(look) * c.fwdSign > 0.3
		end
		if state.top > 0 and forwardOk then
			local ceiling = (60 + state.top * 3.4) / STUDS_TO_KMH -- 100 = около 400 км/ч
			if speed < ceiling then
				local taper = math.clamp((ceiling - speed) / (ceiling * 0.12), 0, 1)
				extra = extra + TOP_ACCEL * (1 + state.accel * 0.06) * taper
			end
		end
	end

	extra = math.min(extra, MAX_EXTRA)
	if extra <= 0 or not pushDir then
		return
	end

	root:ApplyImpulse(pushDir * root.AssemblyMass * extra * dt)
	c.expected = speed + extra * dt
	c.pushedAt = os.clock()
end

connect(RunService.Heartbeat, function(dt)
	refreshCar()
	if not car then
		return
	end
	updateSprings(dt)
	updateBoost(dt)
end)

------------------------------------------------------------------------
-- ИНТЕРФЕЙС
------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "KRP_Menu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

pcall(function()
	if gethui then
		gui.Parent = gethui()
	else
		gui.Parent = game:GetService("CoreGui")
	end
end)
if not gui.Parent then
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function newInstance(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function styleText(obj, size, color)
	obj.Font = FONT
	obj.TextSize = size
	obj.TextColor3 = color or COLOR_WHITE
	obj.TextStrokeColor3 = COLOR_BLACK
	obj.TextStrokeTransparency = STROKE_T
end

local function corner(obj, r)
	newInstance("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function outline(obj, thickness)
	return newInstance("UIStroke", {
		Color = COLOR_WHITE,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, obj)
end

local function screenSize()
	local s = gui.AbsoluteSize
	if s.X < 10 then
		local cam = workspace.CurrentCamera
		s = cam and cam.ViewportSize or Vector2.new(800, 600)
	end
	return s
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- окно
local WIN_W, WIN_H = 290, 236
local startSize = screenSize()

local main = newInstance("Frame", {
	Name = "Main",
	Size = UDim2.fromOffset(WIN_W, WIN_H),
	Position = UDim2.fromOffset(20, math.max(20, startSize.Y * 0.2)),
	BackgroundColor3 = COLOR_BODY,
	BorderSizePixel = 0,
	Active = true,
}, gui)
corner(main, 10)

-- ярлычок сверху: только за него окно двигается
local header = newInstance("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 28),
	BackgroundColor3 = COLOR_HEADER,
	BorderSizePixel = 0,
	Active = true,
}, main)
corner(header, 10)
newInstance("Frame", {
	Size = UDim2.new(1, 0, 0, 10),
	Position = UDim2.new(0, 0, 1, -10),
	BackgroundColor3 = COLOR_HEADER,
	BorderSizePixel = 0,
}, header)
local title = newInstance("TextLabel", {
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	Text = "Кемерово РП",
}, header)
styleText(title, 18)

local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
connect(header.InputBegan, function(input)
	if isPress(input) then
		dragging = true
		dragInput = input
		dragStart = input.Position
		startPos = main.Position
	end
end)
connect(UserInputService.InputChanged, function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input == dragInput) then
		local d = input.Position - dragStart
		local size = screenSize()
		local x = math.clamp(startPos.X.Offset + d.X, 0, math.max(0, size.X - WIN_W))
		local y = math.clamp(startPos.Y.Offset + d.Y, 0, math.max(0, size.Y - WIN_H))
		main.Position = UDim2.fromOffset(x, y)
	end
end)
connect(UserInputService.InputEnded, function(input)
	if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
		dragging = false
		dragInput = nil
	end
end)

-- вкладки
local tabBar = newInstance("Frame", {
	Position = UDim2.fromOffset(14, 36),
	Size = UDim2.fromOffset(262, 30),
	BackgroundTransparency = 1,
}, main)
newInstance("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, tabBar)

local pagesHolder = newInstance("Frame", {
	Position = UDim2.fromOffset(14, 76),
	Size = UDim2.fromOffset(262, 150),
	BackgroundTransparency = 1,
}, main)

local pages, tabButtons = {}, {}

local function setTab(index)
	for i, page in ipairs(pages) do
		page.Visible = (i == index)
		TweenService:Create(tabButtons[i], TweenInfo.new(0.15), {
			BackgroundTransparency = (i == index) and 0.5 or 0.82,
		}):Play()
	end
end

local function newTab(index, name)
	local btn = newInstance("TextButton", {
		Size = UDim2.new(1 / 3, -4, 1, 0),
		LayoutOrder = index,
		BackgroundColor3 = COLOR_WHITE,
		BackgroundTransparency = 0.82,
		AutoButtonColor = false,
		Text = name,
	}, tabBar)
	styleText(btn, 17)
	corner(btn, 6)
	outline(btn, 1.5)
	tabButtons[index] = btn
	connect(btn.MouseButton1Click, function()
		setTab(index)
	end)

	local page = newInstance("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Visible = false,
	}, pagesHolder)
	pages[index] = page
	return page
end

-- красная надпись «сядьте в машину»
local function showWarning(page, rowY)
	local old = page:FindFirstChild("Warn")
	if old then
		old:Destroy()
	end
	local y0 = rowY + 28
	local lbl = newInstance("TextLabel", {
		Name = "Warn",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, y0),
		BackgroundTransparency = 1,
		Text = "СЯДЬТЕ В МАШИНУ ДЛЯ ИСПОЛЬЗОВАНИЯ",
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 10,
	}, page)
	styleText(lbl, 15, COLOR_RED)
	lbl.TextStrokeTransparency = 0.35

	task.delay(0.5, function()
		if lbl.Parent then
			local tw = TweenService:Create(lbl, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromOffset(0, y0 - 24),
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			})
			tw.Completed:Connect(function()
				lbl:Destroy()
			end)
			tw:Play()
		end
	end)
end

-- переключатель: белый квадратик, при включении заливается белым
local function makeToggle(page, y, text, key)
	local row = newInstance("TextButton", {
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, y),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, page)
	local box = newInstance("Frame", {
		Size = UDim2.fromOffset(22, 22),
		Position = UDim2.fromOffset(2, 3),
		BackgroundColor3 = COLOR_WHITE,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, row)
	corner(box, 5)
	outline(box, 2)
	local lbl = newInstance("TextLabel", {
		Size = UDim2.new(1, -36, 1, 0),
		Position = UDim2.fromOffset(36, 0),
		BackgroundTransparency = 1,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	styleText(lbl, 19)

	local function paint(on)
		TweenService:Create(box, TweenInfo.new(0.12), { BackgroundTransparency = on and 0 or 1 }):Play()
	end

	connect(row.MouseButton1Click, function()
		if state[key] then
			state[key] = false
			paint(false)
			return
		end
		refreshCar()
		if not car then
			showWarning(page, y)
			return
		end
		state[key] = true
		paint(true)
	end)
end

-- ползунок
local function makeSlider(page, y, titleText, minV, maxV, initV, suffix, onChange)
	local holder = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, y),
		BackgroundTransparency = 1,
	}, page)
	local lbl = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, holder)
	styleText(lbl, 17)

	local track = newInstance("Frame", {
		Size = UDim2.new(1, -16, 0, 6),
		Position = UDim2.fromOffset(8, 30),
		BackgroundColor3 = COLOR_WHITE,
		BackgroundTransparency = 0.65,
		BorderSizePixel = 0,
	}, holder)
	corner(track, 3)
	local bar = newInstance("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = COLOR_WHITE,
		BorderSizePixel = 0,
	}, track)
	corner(bar, 3)
	local knob = newInstance("Frame", {
		Size = UDim2.fromOffset(16, 16),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = COLOR_WHITE,
		BorderSizePixel = 0,
	}, track)
	corner(knob, 8)
	newInstance("UIStroke", { Color = COLOR_BLACK, Thickness = 1, Transparency = 0.6 }, knob)

	local hit = newInstance("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.fromOffset(0, 18),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, holder)

	local function setValue(v, silent)
		v = math.clamp(math.floor(v + 0.5), minV, maxV)
		local a = (v - minV) / (maxV - minV)
		bar.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
		lbl.Text = titleText .. ": " .. tostring(v) .. suffix
		if not silent then
			onChange(v)
		end
	end
	local function fromX(x)
		local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		setValue(minV + a * (maxV - minV))
	end

	local active = nil
	connect(hit.InputBegan, function(input)
		if isPress(input) then
			active = input
			fromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if active and (input.UserInputType == Enum.UserInputType.MouseMovement or input == active) then
			fromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if active and (input == active or input.UserInputType == Enum.UserInputType.MouseButton1) then
			active = nil
		end
	end)

	setValue(initV, true)
	return { set = setValue }
end

-- поле ввода числа 0-100
local function makeField(page, y, labelText, initV, onChange)
	local lbl = newInstance("TextLabel", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, -80, 0, 28),
		BackgroundTransparency = 1,
		Text = labelText,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, page)
	styleText(lbl, 18)

	local box = newInstance("TextBox", {
		Position = UDim2.new(1, -70, 0, y + 1),
		Size = UDim2.fromOffset(70, 26),
		BackgroundColor3 = COLOR_WHITE,
		BackgroundTransparency = 0.82,
		Text = tostring(initV),
		PlaceholderText = "0-100",
		PlaceholderColor3 = Color3.fromRGB(225, 225, 225),
		ClearTextOnFocus = false,
	}, page)
	styleText(box, 18)
	corner(box, 6)
	outline(box, 1.5)

	local value = initV

	-- пока печатаешь: только цифры, не больше трёх
	connect(box:GetPropertyChangedSignal("Text"), function()
		local clean = box.Text:gsub("%D", "")
		if #clean > 3 then
			clean = clean:sub(1, 3)
		end
		if clean ~= box.Text then
			box.Text = clean
		end
	end)

	-- когда закончил: число зажимается в 0-100, пустое возвращает прежнее
	connect(box.FocusLost, function()
		local n = tonumber(box.Text)
		if n then
			value = math.clamp(math.floor(n + 0.5), 0, 100)
			onChange(value)
		end
		box.Text = tostring(value)
	end)
end

-- белая кнопка
local function makeButton(parent, text, pos, size, onClick)
	local b = newInstance("TextButton", {
		Position = pos,
		Size = size,
		BackgroundColor3 = COLOR_WHITE,
		BackgroundTransparency = 0.82,
		AutoButtonColor = false,
		Text = text,
	}, parent)
	styleText(b, 17)
	corner(b, 6)
	outline(b, 1.5)
	connect(b.MouseButton1Click, function()
		b.BackgroundTransparency = 0.55
		TweenService:Create(b, TweenInfo.new(0.25), { BackgroundTransparency = 0.82 }):Play()
		onClick()
	end)
	return b
end

local function makeInfo(page, y, h, size)
	local lbl = newInstance("TextLabel", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, h),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "",
	}, page)
	styleText(lbl, size)
	return lbl
end

-- вкладка 1: ПНЕВМО
local pagePneumo = newTab(1, "ПНЕВМО")
makeToggle(pagePneumo, 0, "Пневмо", "pneumo")
local heightSlider = makeSlider(pagePneumo, 38, "Высота", -60, 80, 0, "%", function(v)
	state.height = v
end)
local bw = (262 - 12) / 3
local presets = { { "Низко", -50 }, { "Норма", 0 }, { "Высоко", 60 } }
for i, pr in ipairs(presets) do
	makeButton(pagePneumo, pr[1], UDim2.fromOffset((i - 1) * (bw + 6), 92), UDim2.fromOffset(bw, 30), function()
		heightSlider.set(pr[2])
	end)
end
local statusPneumo = makeInfo(pagePneumo, 128, 20, 15)

-- вкладка 2: БУСТЕР
local pageBoost = newTab(2, "БУСТЕР")
makeToggle(pageBoost, 0, "Бустер", "boost")
makeField(pageBoost, 40, "Ускорение", state.accel, function(v)
	state.accel = v
end)
makeField(pageBoost, 76, "Макс. скорость", state.top, function(v)
	state.top = v
end)
makeInfo(pageBoost, 110, 18, 14).Text = "Введи число от 0 до 100 (0 — выключено)"
local boostStatus = makeInfo(pageBoost, 132, 18, 15)

-- вкладка 3: Подвеска
local pageSusp = newTab(3, "Подвеска")
makeToggle(pageSusp, 0, "Подвеска", "susp")
makeSlider(pageSusp, 38, "Жёсткость", 40, 200, state.stiff, "%", function(v)
	state.stiff = v
end)
makeSlider(pageSusp, 88, "Демпфирование", 40, 200, state.damp, "%", function(v)
	state.damp = v
end)
local statusSusp = makeInfo(pageSusp, 134, 20, 15)

setTab(1)

-- подписи, которые обновляются сами
task.spawn(function()
	while alive do
		local noSprings = car ~= nil and car.count == 0
		local msg = noSprings and "Пружины подвески этой машины не найдены" or ""
		statusPneumo.Text = msg
		statusSusp.Text = msg

		local boostMsg = ""
		if car and state.boost then
			boostMsg = (os.clock() - car.pushedAt < 0.3) and "Разгон применяется" or "Жми газ"
		end
		boostStatus.Text = boostMsg
		task.wait(0.25)
	end
end)

------------------------------------------------------------------------
-- ОЧИСТКА при повторном запуске
------------------------------------------------------------------------
env.KRP_Cleanup = function()
	alive = false
	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	if car then
		restoreSprings(car)
		car = nil
	end
	gui:Destroy()
end
