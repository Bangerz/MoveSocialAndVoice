--[[
	Move Social and Voice — drag bar moves ChatAlertFrame (voice/chat alert stack; see VoiceActivityNotification.lua).
	While dragging: C_Timer poll reapplies anchor every frame; HookScript(OnUpdate) + hooksecurefunc(ChatAlertFrame.UpdateAnchors) after Blizzard.
	Quick Join / channel buttons follow Blizzard layout with the stack.
]]

local ADDON_NAME = ...

local defaults = {
	unlocked = false,
}

local db
local initDone
local handleFrame
local handleClickOverlay
local handleLabelPlane
local settingsCategory
local loader = CreateFrame("Frame")

local mvoDraggingVm = false
local mvoGrabDX, mvoGrabDY = 0, 0
local mvoDragUpdateCount = 0
local mvoLeftBtnWasDown = false
local mvoLayoutAccum = 0
local mvoDragTicker
local mvoArmDrag
local mvoTickerErrPrinted

-- Bumped when handle structure changes (forces rebuild without /reload).
local HANDLE_REV = 1
local CLICK_OVERLAY_FRAME_LEVEL = 65000

local function TeardownHandle()
	if not handleFrame then
		return
	end
	handleFrame:Hide()
	handleFrame:SetScript("OnUpdate", nil)
	loader:SetScript("OnUpdate", nil)
	if handleClickOverlay then
		handleClickOverlay:SetScript("OnEnter", nil)
		handleClickOverlay:SetScript("OnLeave", nil)
	end
	if _G.MoveSocialAndVoiceHandle == handleFrame then
		_G.MoveSocialAndVoiceHandle = nil
	end
	handleFrame = nil
	handleClickOverlay = nil
	handleLabelPlane = nil
	if mvoDragTicker then
		mvoDragTicker:Cancel()
		mvoDragTicker = nil
	end
	mvoDraggingVm = false
	mvoLeftBtnWasDown = false
	mvoLayoutAccum = 0
	mvoArmDrag = nil
end

-- Retail ColorTexture can spawn UnknownAsset children that steal hits; strip mouse everywhere except our overlay.
local function StripMouseExcept(f, ...)
	local keep = {}
	for i = 1, select("#", ...) do
		local k = select(i, ...)
		if k then
			keep[k] = true
		end
	end
	for _, ch in ipairs({ f:GetChildren() }) do
		if not keep[ch] then
			if ch.EnableMouse then
				ch:EnableMouse(false)
			end
			if ch.SetMouseClickEnabled then
				ch:SetMouseClickEnabled(false)
			end
			if ch.SetMouseMotionEnabled then
				ch:SetMouseMotionEnabled(false)
			end
			StripMouseExcept(ch)
		end
	end
end

-- UnknownAsset frames nested *under* the click overlay still sit above the parent in hit order; strip them so the overlay receives events.
local function StripAllChildMouse(f)
	for _, ch in ipairs({ f:GetChildren() }) do
		if ch.EnableMouse then
			ch:EnableMouse(false)
		end
		if ch.SetMouseClickEnabled then
			ch:SetMouseClickEnabled(false)
		end
		if ch.SetMouseMotionEnabled then
			ch:SetMouseMotionEnabled(false)
		end
		StripAllChildMouse(ch)
	end
end

local function RaiseClickOverlayOnly()
	if not handleClickOverlay then
		return
	end
	handleClickOverlay:SetFrameLevel(CLICK_OVERLAY_FRAME_LEVEL)
	if handleClickOverlay.Raise then
		handleClickOverlay:Raise()
	end
end

local function RefreshClickOverlayStack()
	if not handleFrame or not handleClickOverlay then
		return
	end
	StripMouseExcept(handleFrame, handleClickOverlay, handleLabelPlane)
	StripAllChildMouse(handleClickOverlay)
	handleClickOverlay:EnableMouse(true)
	if handleClickOverlay.SetMouseClickEnabled then
		handleClickOverlay:SetMouseClickEnabled(true)
	end
	if handleClickOverlay.SetMouseMotionEnabled then
		handleClickOverlay:SetMouseMotionEnabled(true)
	end
	RaiseClickOverlayOnly()
	if handleLabelPlane then
		handleLabelPlane:SetFrameLevel(CLICK_OVERLAY_FRAME_LEVEL + 100)
		if handleLabelPlane.Raise then
			handleLabelPlane:Raise()
		end
	end
end

-- Visible speaking indicators use ChatAlertFrame:AddAutoAnchoredSubSystem; layout ignores VoiceActivityManager position.
local function GetVm()
	local caf = _G.ChatAlertFrame
	if caf and caf.ClearAllPoints and caf.SetPoint then
		return caf
	end
	local vam = _G.VoiceActivityManager
	if vam and vam.ClearAllPoints and vam.SetPoint then
		return vam
	end
	return nil
end

-- Blizzard reapplies ChatAlert layout after SetPoint; we re-anchor after OnUpdate and after UpdateAnchors (see MvoInstallChatAlertLayoutHooks).
local mvoApplyingVmPos = false

local function MvoApplyVmAnchorRaw(v, cx, cy)
	if not v then
		return
	end
	mvoApplyingVmPos = true
	v:ClearAllPoints()
	v:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
	mvoApplyingVmPos = false
end

local function MergeDefaults()
	for k, v in pairs(defaults) do
		if db[k] == nil then
			db[k] = v
		end
	end
	-- Removed features (1.8.x pin experiment); drop keys so SavedVariables stay small.
	db.debug = nil
	db.pinQuickJoinToast = nil
	db.quickJoinCx = nil
	db.quickJoinCy = nil
end

local function GetAnchorFrame(name)
	if not name or name == "" then
		return UIParent
	end
	return _G[name] or UIParent
end

local function ClearSavedVmPosition()
	db.point = nil
	db.relativeTo = nil
	db.relativePoint = nil
	db.xOfs = nil
	db.yOfs = nil
end

local function SavedPositionLooksCorrupt()
	if not db.point then
		return false
	end
	local x, y = db.xOfs or 0, db.yOfs or 0
	if x ~= x or y ~= y then
		return true
	end
	local pw, ph = UIParent:GetSize()
	pw = pw or 2000
	ph = ph or 2000
	if math.abs(x) > pw * 3 or math.abs(y) > ph * 3 then
		return true
	end
	return false
end

local function ClampVmBottomLeft(blX, blY, v)
	v = v or GetVm()
	if not v then
		return blX, blY
	end
	local pw, ph = UIParent:GetSize()
	pw = pw or 2000
	ph = ph or 2000
	local vw, vh = v:GetSize()
	vw = math.max(vw or 0, 48)
	vh = math.max(vh or 0, 48)
	local pad = 8
	blX = math.max(pad, math.min(blX, pw - vw - pad))
	blY = math.max(pad, math.min(blY, ph - vh - pad))
	return blX, blY
end

local function ClampVmCenter(cx, cy, v)
	v = v or GetVm()
	if not v then
		return cx, cy
	end
	local pw, ph = UIParent:GetSize()
	pw = pw or 2000
	ph = ph or 2000
	local vw, vh = v:GetWidth(), v:GetHeight()
	vw = math.max(vw or 0, 48)
	vh = math.max(vh or 0, 48)
	local pad = 8
	local hwx, hhy = vw / 2, vh / 2
	cx = math.max(pad + hwx, math.min(cx, pw - pad - hwx))
	cy = math.max(pad + hhy, math.min(cy, ph - pad - hhy))
	return cx, cy
end

local function SavePosition()
	local v = GetVm()
	if not v or not v.GetPoint then
		return
	end
	local point, rel, relPt, x, y = v:GetPoint(1)
	if not point then
		return
	end
	db.point = point
	db.relativePoint = relPt or "CENTER"
	db.xOfs = x or 0
	db.yOfs = y or 0
	if rel and rel.GetName then
		local n = rel:GetName()
		db.relativeTo = (n and n ~= "") and n or "UIParent"
	else
		db.relativeTo = "UIParent"
	end
	if db.relativeTo == "UIParent" and db.point == "BOTTOMLEFT" then
		db.xOfs, db.yOfs = ClampVmBottomLeft(db.xOfs or 0, db.yOfs or 0, v)
	end
	if db.relativeTo == "UIParent" and db.point == "CENTER" then
		db.xOfs, db.yOfs = ClampVmCenter(db.xOfs or 0, db.yOfs or 0, v)
	end
end

local function ApplySavedPosition()
	local v = GetVm()
	if not v then
		return
	end
	if SavedPositionLooksCorrupt() then
		ClearSavedVmPosition()
		return
	end
	if not db.point then
		return
	end
	local rel = GetAnchorFrame(db.relativeTo)
	mvoApplyingVmPos = true
	v:ClearAllPoints()
	v:SetPoint(db.point, rel, db.relativePoint or "CENTER", db.xOfs or 0, db.yOfs or 0)
	if db.relativeTo == "UIParent" and db.point == "BOTTOMLEFT" then
		local x, y = ClampVmBottomLeft(db.xOfs or 0, db.yOfs or 0, v)
		if x ~= db.xOfs or y ~= db.yOfs then
			v:ClearAllPoints()
			v:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
			db.xOfs, db.yOfs = x, y
		end
	end
	if db.relativeTo == "UIParent" and db.point == "CENTER" then
		local x, y = ClampVmCenter(db.xOfs or 0, db.yOfs or 0, v)
		if x ~= db.xOfs or y ~= db.yOfs then
			v:ClearAllPoints()
			v:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
			db.xOfs, db.yOfs = x, y
		end
	end
	mvoApplyingVmPos = false
end

local function MvoGetAnchorOuterRect(v)
	if not v then
		return nil
	end
	if v.GetScaledRect then
		local l, b, w, h = v:GetScaledRect()
		if l and b and w and h and w > 4 and h > 4 then
			return l, b, w, h
		end
	end
	if v.GetBoundingRect then
		local l, b, w, h = v:GetBoundingRect()
		if l and b and w and h and w > 4 and h > 4 then
			return l, b, w, h
		end
	end
	local l, b, w, h = v:GetRect()
	if l and b and w and h and w > 4 and h > 4 then
		return l, b, w, h
	end
	return nil
end

local function LayoutHandle()
	if not handleFrame then
		return
	end
	-- Always pin to UIParent. Do not parent the handle to the voice anchor frame or it can follow off-screen saves.
	handleFrame:SetParent(UIParent)
	handleFrame:ClearAllPoints()
	-- Below TOOLTIP strata so GameTooltip draws above this bar; still above most UI.
	handleFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	handleFrame:SetFrameLevel(5000)
	handleFrame:SetClampedToScreen(true)
	local placed = false
	if db and db.unlocked then
		local v = GetVm()
		local l, b, w, h = MvoGetAnchorOuterRect(v)
		if l and b and w and h then
			handleFrame:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", l + w / 2, b + h + 10)
			placed = true
		end
	end
	if not placed then
		handleFrame:SetPoint("TOP", UIParent, "TOP", 0, -96)
	end
	if handleFrame.SetToplevel then
		handleFrame:SetToplevel(true)
	end
	if handleFrame.Raise then
		handleFrame:Raise()
	end
	RefreshClickOverlayStack()
end

-- Drag uses the addon loader's OnUpdate so we tick every frame even if the handle's OnUpdate misbehaves.
local function MvoCursorUIParentXY()
	local s = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	return x / s, y / s
end

local function MvoReapplyDragVmPosition()
	-- Do not gate on mvoApplyingVmPos: SetPoint on ChatAlertFrame can call UpdateAnchors while that flag is set; nested hooks must reapply the drag anchor.
	if not mvoDraggingVm or InCombatLockdown() then
		return
	end
	local v = GetVm()
	if not v then
		return
	end
	local mx, my = MvoCursorUIParentXY()
	local ncx, ncy = ClampVmCenter(mx - mvoGrabDX, my - mvoGrabDY, v)
	MvoApplyVmAnchorRaw(v, ncx, ncy)
end

-- HookScript runs after Blizzard's frame OnUpdate.
local function MvoChatAlertPostLayoutOnUpdate(self, _)
	local v = GetVm()
	if not v or self ~= v or not mvoDraggingVm then
		return
	end
	MvoReapplyDragVmPosition()
end

-- After ChatAlertFrame:UpdateAnchors() (repositions Quick Join / channel buttons with the stack).
local function MvoChatAlertPostUpdateAnchors()
	MvoReapplyDragVmPosition()
end

local function MvoInstallCafUpdateAnchorsHook()
	local caf = _G.ChatAlertFrame
	if caf and caf.UpdateAnchors and hooksecurefunc and not caf._mvoMvoUpdateAnchorsHook then
		caf._mvoMvoUpdateAnchorsHook = true
		hooksecurefunc(caf, "UpdateAnchors", MvoChatAlertPostUpdateAnchors)
	end
end

local function MvoInstallVmOnUpdateHook()
	local v = GetVm()
	if v and v.HookScript and not v._mvoPostLayoutHook then
		v._mvoPostLayoutHook = true
		v:HookScript("OnUpdate", MvoChatAlertPostLayoutOnUpdate)
	end
end

local function MvoInstallChatAlertLayoutHooks()
	MvoInstallCafUpdateAnchorsHook()
	MvoInstallVmOnUpdateHook()
end

local function MvoPointerOnHandle()
	if not handleFrame or not handleFrame:IsShown() then
		return false
	end
	if handleClickOverlay and (handleClickOverlay:IsMouseOver() or handleFrame:IsMouseOver()) then
		return true
	end
	if handleLabelPlane and handleLabelPlane:IsMouseOver() then
		return true
	end
	if GetMouseFocus then
		local f = GetMouseFocus()
		local p = f
		while p do
			if p == handleFrame or p == handleClickOverlay or p == handleLabelPlane then
				return true
			end
			p = p:GetParent()
		end
	end
	local x, y = GetCursorPosition()
	local us = UIParent:GetEffectiveScale()
	x, y = x / us, y / us
	local pad = 32
	if handleFrame.GetScaledRect then
		local l, b, w, h = handleFrame:GetScaledRect()
		if l and b and w and h and w > 0 and h > 0 then
			return x >= l - pad and x <= l + w + pad and y >= b - pad and y <= b + h + pad
		end
	end
	local l, b, w, h = handleFrame:GetRect()
	if not l or not b or not w or not h or w <= 0 or h <= 0 then
		return false
	end
	return x >= l - pad and x <= l + w + pad and y >= b - pad and y <= b + h + pad
end

-- Derive bottom-left from anchors when GetRect is still nil (anchor frame often reports shown=true before layout).
local function VmBottomLeftFromAnchors(v)
	local pt, rel, rpt, x, y = v:GetPoint(1)
	if not pt or not rel then
		return nil, nil
	end
	rpt = rpt or "BOTTOMLEFT"
	x, y = x or 0, y or 0
	local w, h = v:GetWidth(), v:GetHeight()
	if not w or not h or w < 1 or h < 1 then
		w, h = 160, 56
	end

	if rel == UIParent then
		local pL, pB, pW, pH = UIParent:GetRect()
		if not pL or not pB or not pW or not pH or pW < 1 or pH < 1 then
			pW, pH = UIParent:GetSize()
			pL, pB = 0, 0
		end
		local pTop = pB + pH
		local pMidX = pL + pW / 2
		if pt == "BOTTOMLEFT" and rpt == "BOTTOMLEFT" then
			return pL + x, pB + y
		end
		if pt == "BOTTOM" and rpt == "BOTTOM" then
			return pMidX + x - w / 2, pB + y
		end
		if pt == "TOP" and rpt == "TOP" then
			return pMidX + x - w / 2, (pTop + y) - h
		end
		if pt == "TOPLEFT" and rpt == "TOPLEFT" then
			return pL + x, (pTop + y) - h
		end
		if pt == "CENTER" and rpt == "CENTER" then
			return pMidX + x - w / 2, pB + pH / 2 + y - h / 2
		end
	end

	-- Sibling (or other direct child of UIParent): GetLeft/Bottom are in UIParent space.
	if rel.GetParent and rel:GetParent() == UIParent then
		if pt == "BOTTOMLEFT" and rpt == "BOTTOMLEFT" then
			local rl, rb = rel:GetLeft(), rel:GetBottom()
			if rl ~= nil and rb ~= nil then
				return rl + x, rb + y
			end
		end
		if pt == "BOTTOM" and rpt == "BOTTOM" then
			local rl, rb = rel:GetLeft(), rel:GetBottom()
			local rw, rh = rel:GetWidth(), rel:GetHeight()
			if rl and rb and rw and rh and rw > 1 and rh > 1 then
				return rl + rw / 2 + x - w / 2, rb + y
			end
		end
		if pt == "TOP" and rpt == "TOP" then
			local rl, rb = rel:GetLeft(), rel:GetBottom()
			local rw, rh = rel:GetWidth(), rel:GetHeight()
			if rl and rb and rw and rh and rw > 1 and rh > 1 then
				local rt = rb + rh
				return rl + rw / 2 + x - w / 2, (rt + y) - h
			end
		end
		if pt == "TOPLEFT" and rpt == "TOPLEFT" then
			local rl, rb = rel:GetLeft(), rel:GetBottom()
			local rw, rh = rel:GetWidth(), rel:GetHeight()
			if rl and rb and rw and rh and rw > 1 and rh > 1 then
				return rl + x, (rb + rh + y) - h
			end
		end
	end

	return nil, nil
end

-- Bottom-left of anchor frame in UIParent space (same as MvoCursorUIParentXY). Never use 0,0 as a fake fallback.
local function GetVmBottomLeftUIParent(v)
	if not v then
		return nil, nil, "no frame"
	end
	if v.GetBoundingRect then
		local l, b, w, h = v:GetBoundingRect()
		if l and b and w and h and w > 1 and h > 1 then
			return l, b, nil
		end
	end
	local gl, gb = v:GetLeft(), v:GetBottom()
	if gl ~= nil and gb ~= nil then
		return gl, gb, nil
	end
	if v.GetScaledRect then
		local l, b, w, h = v:GetScaledRect()
		if l and b and w and h and w > 1 and h > 1 then
			return l, b, nil
		end
	end
	local l, b, w, h = v:GetRect()
	if l and b and w and h and w > 1 and h > 1 and v:GetParent() == UIParent then
		return l, b, nil
	end
	local al, ab = VmBottomLeftFromAnchors(v)
	if al and ab then
		return al, ab, "anchors"
	end
	if db and db.point == "BOTTOMLEFT" and (not db.relativeTo or db.relativeTo == "UIParent") then
		local ox, oy = db.xOfs, db.yOfs
		if type(ox) == "number" and type(oy) == "number" and ox == ox and oy == oy then
			return ox, oy, "savedDB"
		end
	end
	return nil, nil, "layout not ready (no rect, anchors, or saved BL)"
end

-- Cursor + drag use frame center in UIParent BL space (matches MvoCursorUIParentXY). Better than BOTTOMLEFT for wide ChatAlertFrame.
local function GetVmCenterUIParent(v)
	if not v then
		return nil, nil, "no frame"
	end
	local cx, cy = v:GetCenter()
	if cx and cy then
		return cx, cy, nil
	end
	if db and db.point == "CENTER" and (not db.relativeTo or db.relativeTo == "UIParent") then
		local ox, oy = db.xOfs, db.yOfs
		if type(ox) == "number" and type(oy) == "number" and ox == ox and oy == oy then
			return ox, oy, "savedCENTER"
		end
	end
	local blx, bly, err = GetVmBottomLeftUIParent(v)
	if not blx then
		return nil, nil, err
	end
	local w, h = v:GetWidth(), v:GetHeight()
	if not w or not h or w < 1 or h < 1 then
		w, h = 160, 56
	end
	return blx + w / 2, bly + h / 2, "fromBL"
end

local function MvoTryBeginDrag()
	GameTooltip:Hide()
	local v = GetVm()
	if not v then
		print("|cff99cc66Move Social and Voice|r: Blizzard voice frame not ready yet — wait a moment and try again.")
		return
	end
	if InCombatLockdown() then
		print("|cff99cc66Move Social and Voice|r: Can't move UI while in combat.")
		return
	end
	mvoDragUpdateCount = 0
	local mx, my = MvoCursorUIParentXY()
	local vcX, vcY = GetVmCenterUIParent(v)
	if not vcX or not vcY then
		mvoArmDrag = { expire = GetTime() + 2 }
		print(
			"|cff99cc66Move Social and Voice|r: Voice UI is still laying out. |cff888888Hold the click|r a moment, or click again — the addon retries for ~2s."
		)
		return
	end
	mvoArmDrag = nil
	mvoGrabDX = mx - vcX
	mvoGrabDY = my - vcY
	mvoDraggingVm = true
end

local function MvoStopDragPoll()
	if mvoDragTicker then
		mvoDragTicker:Cancel()
		mvoDragTicker = nil
	end
	loader:SetScript("OnUpdate", nil)
	mvoLeftBtnWasDown = false
	mvoLayoutAccum = 0
	mvoArmDrag = nil
end

local function MvoDragOnUpdate(_, elapsed)
	if not db or not db.unlocked or not handleFrame or not handleFrame:IsShown() then
		return
	end

	local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown(1)
	local wasDown = mvoLeftBtnWasDown
	mvoLeftBtnWasDown = down

	local vEarly = GetVm()
	if mvoArmDrag and not mvoDraggingVm and vEarly then
		if not down then
			mvoArmDrag = nil
		elseif GetTime() > mvoArmDrag.expire then
			mvoArmDrag = nil
			print(
				"|cff99cc66Move Social and Voice|r: Still no layout from Blizzard's voice frame after ~2s. Wait for the voice UI to appear, then try again."
			)
		else
			local mx, my = MvoCursorUIParentXY()
			local vcx, vcy = GetVmCenterUIParent(vEarly)
			if vcx and vcy then
				mvoGrabDX = mx - vcx
				mvoGrabDY = my - vcy
				mvoDraggingVm = true
				mvoDragUpdateCount = 0
				mvoArmDrag = nil
			end
		end
	end

	if down and not wasDown then
		local ptr = MvoPointerOnHandle()
		if ptr then
			MvoTryBeginDrag()
		end
	end
	if not down and wasDown then
		if mvoArmDrag then
			mvoArmDrag = nil
		end
		if mvoDraggingVm then
			mvoDraggingVm = false
			SavePosition()
			LayoutHandle()
		end
	end

	local v = GetVm()
	if mvoDraggingVm then
		if not v then
			mvoDraggingVm = false
		else
			mvoDragUpdateCount = mvoDragUpdateCount + 1
			if mvoDragUpdateCount > 2 and not (IsMouseButtonDown("LeftButton") or IsMouseButtonDown(1)) then
				mvoDraggingVm = false
				SavePosition()
				LayoutHandle()
				return
			end
			if InCombatLockdown() then
				mvoDraggingVm = false
				SavePosition()
				LayoutHandle()
				return
			end
			-- Ticker must reapply every frame: ChatAlertFrame often has no OnUpdate while idle, so hooks alone never moved the stack.
			MvoReapplyDragVmPosition()
			LayoutHandle()
			return
		end
	end

	mvoLayoutAccum = mvoLayoutAccum + elapsed
	if mvoLayoutAccum < 0.2 then
		return
	end
	mvoLayoutAccum = 0
	LayoutHandle()
end

local function MvoStartDragPoll()
	MvoStopDragPoll()
	mvoTickerErrPrinted = false
	mvoLeftBtnWasDown = IsMouseButtonDown("LeftButton") or IsMouseButtonDown(1)
	local okTicker, tickerErr = pcall(function()
		mvoDragTicker = C_Timer.NewTicker(1 / 60, function()
			local ok, err = pcall(MvoDragOnUpdate, nil, 1 / 60)
			if not ok and not mvoTickerErrPrinted then
				mvoTickerErrPrinted = true
				print("|cffff4444Move Social and Voice|r: drag poll error — " .. tostring(err))
			end
		end)
	end)
	if not okTicker then
		print("|cffff4444Move Social and Voice|r: C_Timer.NewTicker failed — " .. tostring(tickerErr))
		loader:SetScript("OnUpdate", function(_, el)
			MvoDragOnUpdate(nil, el or 0)
		end)
	end
end

local function ScheduleInit()
	C_Timer.After(0, TryInit)
end

local function ShowHandleNow()
	if not db or not db.unlocked then
		return
	end
	EnsureHandle()
	if handleFrame then
		LayoutHandle()
		handleFrame:SetAlpha(1)
		handleFrame:EnableMouse(false)
		if handleFrame.SetMouseClickEnabled then
			handleFrame:SetMouseClickEnabled(false)
		end
		if handleClickOverlay then
			handleClickOverlay:EnableMouse(true)
			if handleClickOverlay.SetMouseClickEnabled then
				handleClickOverlay:SetMouseClickEnabled(true)
			end
			if handleClickOverlay.SetMouseMotionEnabled then
				handleClickOverlay:SetMouseMotionEnabled(true)
			end
		end
		handleFrame:Show()
		if handleFrame.Raise then
			handleFrame:Raise()
		end
		C_Timer.After(0, function()
			if handleFrame and db and db.unlocked then
				LayoutHandle()
				handleFrame:Show()
				if handleFrame.Raise then
					handleFrame:Raise()
				end
				RefreshClickOverlayStack()
			end
		end)
		MvoStartDragPoll()
	end
end

local function SetUnlocked(state)
	if not db then
		return
	end
	MergeDefaults()
	db.unlocked = state and true or false
	if db.unlocked then
		ShowHandleNow()
		if not handleFrame then
			C_Timer.After(0.05, ShowHandleNow)
			C_Timer.After(0.5, ShowHandleNow)
		end
	else
		MvoStopDragPoll()
		mvoDraggingVm = false
		local v = GetVm()
		if v then
			v:StopMovingOrSizing()
		end
		if handleFrame then
			handleFrame:Hide()
		end
		SavePosition()
	end
end

function EnsureHandle()
	if handleFrame and handleFrame._mvoRev ~= HANDLE_REV then
		TeardownHandle()
	end
	if handleFrame then
		return
	end
	-- Root holds visuals; ColorTexture can add UnknownAsset children that eat clicks. A texture-free overlay on top gets all mouse input.
	handleFrame = CreateFrame("Frame", "MoveSocialAndVoiceHandle", UIParent)
	handleFrame._mvoRev = HANDLE_REV
	handleFrame:SetSize(200, 36)
	local edge = 2
	local border = handleFrame:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", handleFrame, "TOPLEFT", 0, 0)
	border:SetPoint("BOTTOMRIGHT", handleFrame, "BOTTOMRIGHT", 0, 0)
	border:SetColorTexture(0.35, 0.95, 0.45, 1)
	local fill = handleFrame:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", handleFrame, "TOPLEFT", edge, -edge)
	fill:SetPoint("BOTTOMRIGHT", handleFrame, "BOTTOMRIGHT", -edge, edge)
	fill:SetColorTexture(0.06, 0.22, 0.1, 0.92)

	handleClickOverlay = CreateFrame("Button", nil, handleFrame)
	handleClickOverlay:SetAllPoints()
	-- Gives the button a real hit rect; separate textures avoid sharing one object across states.
	local function clearTex()
		local t = handleClickOverlay:CreateTexture()
		t:SetAllPoints()
		t:SetColorTexture(0, 0, 0, 0)
		return t
	end
	handleClickOverlay:SetNormalTexture(clearTex())
	handleClickOverlay:SetPushedTexture(clearTex())
	handleClickOverlay:SetHighlightTexture(clearTex())
	handleClickOverlay:EnableMouse(true)
	if handleClickOverlay.SetMouseClickEnabled then
		handleClickOverlay:SetMouseClickEnabled(true)
	end
	if handleClickOverlay.SetMouseMotionEnabled then
		handleClickOverlay:SetMouseMotionEnabled(true)
	end
	handleClickOverlay:RegisterForClicks("LeftButtonDown", "LeftButtonUp")

	handleFrame:EnableMouse(false)
	if handleFrame.SetMouseClickEnabled then
		handleFrame:SetMouseClickEnabled(false)
	end
	handleFrame:SetMovable(false)

	mvoDraggingVm = false
	mvoDragUpdateCount = 0
	mvoGrabDX, mvoGrabDY = 0, 0
	mvoLeftBtnWasDown = false

	handleClickOverlay:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Move Social and Voice", 1, 1, 1)
		GameTooltip:AddLine(
			"Drag to move the voice/chat alert stack (and Quick Join with it).\n|cff888888/mvo lock|r when done.",
			0.85,
			0.85,
			0.85,
			true
		)
		GameTooltip:Show()
	end)
	handleClickOverlay:SetScript("OnLeave", GameTooltip_Hide)

	handleLabelPlane = CreateFrame("Frame", nil, handleFrame)
	handleLabelPlane:SetAllPoints()
	handleLabelPlane:SetFrameLevel(CLICK_OVERLAY_FRAME_LEVEL + 100)
	handleLabelPlane:EnableMouse(false)
	if handleLabelPlane.SetMouseClickEnabled then
		handleLabelPlane:SetMouseClickEnabled(false)
	end
	local fs = handleLabelPlane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("CENTER", handleLabelPlane, "CENTER", 0, 0)
	fs:SetText(":::  Move Social and Voice")
	fs:SetTextColor(0.85, 1, 0.9)
	if fs.SetMouseClickEnabled then
		fs:SetMouseClickEnabled(false)
	end
	if fs.EnableMouse then
		fs:EnableMouse(false)
	end
	RefreshClickOverlayStack()
	handleFrame:Hide()
end

local function UpdateUnlockUI()
	MergeDefaults()
	if not handleFrame then
		EnsureHandle()
	end
	if not handleFrame then
		return
	end
	if db.unlocked then
		ShowHandleNow()
	else
		MvoStopDragPoll()
		if handleFrame then
			handleFrame:Hide()
		end
	end
end

local function ResetPosition()
	ClearSavedVmPosition()
	local v = GetVm()
	if v then
		mvoApplyingVmPos = true
		v:ClearAllPoints()
		v:SetPoint("TOP", UIParent, "TOP", 0, -120)
		mvoApplyingVmPos = false
	end
	SavePosition()
	EnsureHandle()
	ShowHandleNow()
	print("|cff99cc66Move Social and Voice|r: Position reset to default (top center). |cff888888/mvo unlock|r if the bar is hidden.")
end

local function RecoverUI()
	MergeDefaults()
	ClearSavedVmPosition()
	db.unlocked = true
	local v = GetVm()
	if v then
		mvoApplyingVmPos = true
		v:ClearAllPoints()
		v:SetPoint("TOP", UIParent, "TOP", 0, -120)
		mvoApplyingVmPos = false
	end
	SavePosition()
	EnsureHandle()
	ShowHandleNow()
	ScheduleInit()
	print("|cff99cc66Move Social and Voice|r: Recovered. Handle should appear near the top; |cffaaaaaa/mvo lock|r when done.")
end

local function PrintHelp()
	print("|cff99cc66Move Social and Voice|r — slash: |cffaaaaaa/movevoice|r or |cffaaaaaa/mvo|r")
	print("  |cffaaaaaaunlock| unlock — show handle and drag the voice overlay")
	print("  |cffaaaaaalock| lock — hide handle and save position")
	print("  |cffaaaaaatoggle| — flip unlock")
	print("  |cffaaaaaareset| — default anchor (top center)")
	print("  |cffaaaaaarecover| — clear bad save, unlock, force show handle")
	print("  |cffaaaaaaconfig| — open AddOns options")
end

function TryInit()
	if not db then
		return
	end
	if not C_AddOns.IsAddOnLoaded("Blizzard_Channels") then
		return
	end

	EnsureHandle()

	MvoInstallChatAlertLayoutHooks()

	local v = GetVm()
	if v and not initDone then
		initDone = true
		MergeDefaults()
		if SavedPositionLooksCorrupt() then
			ClearSavedVmPosition()
		end
		ApplySavedPosition()
	end

	if not v then
		C_Timer.After(0.5, TryInit)
	end

	UpdateUnlockUI()
end

local function RegisterOptions()
	if not Settings or not Settings.RegisterVerticalLayoutCategory or settingsCategory then
		return
	end

	local category, layout = Settings.RegisterVerticalLayoutCategory("Move Social and Voice")
	settingsCategory = category:GetID()

	do
		local function GetValue()
			return db.unlocked
		end
		local function SetValue(val)
			SetUnlocked(val)
		end
		local setting = Settings.RegisterProxySetting(
			category,
			"MSV_UNLOCKED",
			Settings.VarType.Boolean,
			"Unlock to move",
			false,
			GetValue,
			SetValue
		)
		Settings.CreateCheckbox(
			category,
			setting,
			"Shows a bar above the voice/chat alert stack. Drag to move ChatAlertFrame (speaker bubbles). Quick Join and channel buttons follow that stack. Lock when finished."
		)
	end

	local resetInit = CreateSettingsButtonInitializer(
		"Reset position",
		"Reset position",
		function()
			ResetPosition()
		end,
		"Move the voice overlay back to the default spot (top center).\n\nSlash: |cffaaaaaa/mvo reset|r or |cffaaaaaa/mvo recover|r.",
		true
	)
	local settingsLayout = layout or (SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(category))
	if settingsLayout and settingsLayout.AddInitializer then
		settingsLayout:AddInitializer(resetInit)
	end

	Settings.RegisterAddOnCategory(category)
end

SLASH_MOVESOCIALVOICE1 = "/movevoice"
SLASH_MOVESOCIALVOICE2 = "/mvo"
SlashCmdList.MOVESOCIALVOICE = function(msg)
	if not db then
		return
	end
	MergeDefaults()
	local a = strlower(((msg or ""):gsub("^%s+", ""):gsub("%s+$", "")))
	if a == "" or a == "toggle" then
		SetUnlocked(not db.unlocked)
		print("|cff99cc66Move Social and Voice|r:", db.unlocked and "Unlocked — drag the handle." or "Locked.")
		return
	end
	if a == "unlock" or a == "on" then
		SetUnlocked(true)
		print("|cff99cc66Move Social and Voice|r: Unlocked — drag the handle.")
		return
	end
	if a == "lock" or a == "off" then
		SetUnlocked(false)
		print("|cff99cc66Move Social and Voice|r: Locked.")
		return
	end
	if a == "reset" then
		ResetPosition()
		return
	end
	if a == "recover" then
		RecoverUI()
		return
	end
	if a == "config" or a == "options" or a == "opt" then
		if settingsCategory and Settings and Settings.OpenToCategory then
			Settings.OpenToCategory(settingsCategory)
		else
			print("|cff99cc66Move Social and Voice|r: Open |cffaaaaaaEsc > Options > AddOns > Move Social and Voice|r.")
		end
		return
	end
	if a == "help" or a == "?" then
		PrintHelp()
		return
	end
	PrintHelp()
end

loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_ENTERING_WORLD" then
		ScheduleInit()
		return
	end
	if name == ADDON_NAME then
		MoveSocialAndVoiceDB = MoveSocialAndVoiceDB or {}
		db = MoveSocialAndVoiceDB
		MergeDefaults()
		if C_AddOns.IsAddOnLoaded("Blizzard_Channels") then
			ScheduleInit()
		end
		if Settings and Settings.RegisterVerticalLayoutCategory then
			RegisterOptions()
		end
	elseif name == "Blizzard_Channels" then
		ScheduleInit()
	end
end)
