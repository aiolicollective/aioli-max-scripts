/***************************************************************************************
    aioli-ratiomask  (Aioli Ratio Mask)  -  v1.2
    --------------------------------------------------------------------------------
    For 3ds Max 2026 (works on earlier versions with Nitrous too).

    PURPOSE :
      You always render 1:1 (square). This tool draws a matte in the VIEWPORT that
      hides whatever falls outside a chosen crop ratio (16:9, 9:16, 4:5, 3:2, etc.),
      so you can preview the crop WITHOUT ever touching the render settings. The
      render stays 1:1 and you crop freely afterwards.

    HOW IT WORKS :
      - A redraw callback paints over the viewport in screen coordinates.
      - We work out the real render frame inside the viewport (= your 1:1 square).
      - Inside it we work out the target ratio rectangle, centred (or offset).
      - We paint a matte (4 bands) all around that rectangle.
      - We draw the outline + (option) the rule of thirds.
      - renderWidth/renderHeight are never written to -> render ratio untouched.

    VIEWPORT LOCK :
      MAXScript can only draw into the ACTIVE viewport, so the overlay used to
      follow every click. It now honours Max's own render lock (the padlock next
      to the viewport dropdown in Render Setup): once the lock is closed, the
      overlay only shows in the viewport that will actually be rendered and stays
      hidden in the others. Lock open -> old behaviour, it follows the active view.

    SAFE FRAME :
      displaySafeFrames is a single global flag - MAXScript has no per-viewport
      safe frame - so the tool toggles it WHEN THE ACTIVE VIEWPORT CHANGES: on
      when you enter the viewport the overlay draws in, off when you leave it.
      It is left alone in between, so a manual Shift+F in another viewport holds
      until the next viewport change. Untick "Safe frame auto" and the tool never
      writes to it again.

    INSTALLATION :
      Scripting > Run Script... (or drag the .ms into the viewport).
      A "Ratio Crop Mask" window opens. Tick "Enable overlay".
      (Optional) For a permanent button: Customize > Customize User Interface >
      category "aiolicollective" > macro "ratiomask", drag it onto a toolbar.

    Overlay mechanism inspired by Image Comp Helper (Warren Wnuk / C. Buelter).
***************************************************************************************/

global aioli_ratiomask_open   -- entry point called by the macroScript

(
    ----------------------------------------------------------------------------
    -- State shared with the redraw callback (globals, so they survive the call)
    ----------------------------------------------------------------------------
    global RCM_active      = false
    global RCM_aspect      = (16.0/9.0)          -- target ratio = Width / Height
    global RCM_label       = "16:9"
    global RCM_showMask    = true
    global RCM_maskColor   = (color 12 12 12)    -- matte colour (near black)
    global RCM_opacity     = 100                 -- matte density in % (see rcm_fillRect)
    global RCM_showThirds  = false
    global RCM_cropColor   = (color 255 255 255) -- ratio outline + thirds colour
    global RCM_offset      = 0.0                  -- frame offset on the free axis (-100..100)
    global RCM_sfAuto      = true                -- tool drives Max's safe frame
    global RCM_lastVP      = -1                  -- last active viewport seen by the callback

    ----------------------------------------------------------------------------
    -- Ratio presets :  label  ->  aspect (W/H)
    ----------------------------------------------------------------------------
    local presetLabels  = #("1:1","16:9","9:16","4:5","5:4","3:2","2:3","4:3","3:4","2:1","1:2","1.85:1","2.39:1","Custom")
    local presetAspects = #( 1.0, (16.0/9.0), (9.0/16.0), (4.0/5.0), (5.0/4.0), (3.0/2.0), (2.0/3.0), (4.0/3.0), (3.0/4.0), 2.0, 0.5, 1.85, 2.39, 1.0 )

    ----------------------------------------------------------------------------
    -- Is the overlay allowed to draw in the viewport being redrawn ?
    --
    -- gw.* only ever paints into the ACTIVE viewport, so we cannot choose where
    -- the overlay goes; we can only choose when to stay quiet. Max's render lock
    -- gives us the target for free:
    --   rendUseActiveView == false  ->  lock closed, rendViewIndex is rendered
    --   rendUseActiveView == true   ->  lock open, the active viewport is rendered
    -- Lock closed and another viewport active -> we skip, so the overlay stops
    -- hopping around. One viewport only (single layout OR maximized viewport,
    -- both report numViews == 1) -> no ambiguity, we always draw.
    ----------------------------------------------------------------------------
    fn rcm_viewAllowed =
    (
        local ok = true
        try
        (
            if (not rendUseActiveView) and viewport.numViews > 1 do
                ok = (viewport.activeViewport == rendViewIndex)
        )
        catch()
        ok
    )

    ----------------------------------------------------------------------------
    -- Safe frame follows the overlay.
    --
    -- displaySafeFrames is a GLOBAL flag: MAXScript exposes no per-viewport safe
    -- frame, so the best we can do is flip it when the active viewport changes -
    -- on when you enter the viewport the overlay draws in, off when you leave.
    -- Acting only on a change is what makes a manual Shift+F elsewhere stick:
    -- between two viewport changes we never write to the flag.
    -- Writing it triggers another redraw, but by then RCM_lastVP already matches
    -- the active viewport, so the second pass writes nothing and it settles.
    ----------------------------------------------------------------------------
    fn rcm_syncSafeFrame allowed =
    (
        if RCM_sfAuto do
        (
            local vp = -1
            try (vp = viewport.activeViewport) catch()
            if vp != RCM_lastVP do
            (
                RCM_lastVP = vp
                if displaySafeFrames != allowed do displaySafeFrames = allowed
            )
        )
    )

    ----------------------------------------------------------------------------
    -- Works out the real render frame inside the current viewport.
    -- Returns #(offsetX, offsetY, fieldX, fieldY, winX, winY) in screen pixels.
    -- (Same safe-frame logic as Image Comp Helper.)
    ----------------------------------------------------------------------------
    fn rcm_field =
    (
        local winX = gw.getWinSizeX()
        local winY = gw.getWinSizeY()
        local renAspect = renderWidth as float / renderHeight as float
        local winAspect = winX as float / winY as float
        local fieldX = 0.0
        local fieldY = 0.0

        if winAspect > renAspect then
        (
            local ff = winY as float / renderHeight as float
            fieldY = winY
            fieldX = ff * renderWidth
        )
        else
        (
            local ff = winX as float / renderWidth as float
            fieldX = winX
            fieldY = ff * renderHeight
        )
        local offX = (winX - fieldX) / 2.0
        local offY = (winY - fieldY) / 2.0
        #(offX, offY, fieldX, fieldY, winX, winY)
    )

    ----------------------------------------------------------------------------
    -- Filled rectangle (the matte) in screen coordinates.
    --
    -- Reliable fill: tightly packed horizontal lines (1 px). gw.wPolyline is the
    -- only primitive that is really stable in Nitrous.
    --
    -- OPACITY: the graphics window has no alpha and no blend mode, so a colour is
    -- always laid down at full strength. What we can do is THIN THE FILL OUT and
    -- let the viewport show through the gaps - a screen door, not a real alpha.
    -- A row is kept when (y * opacity) mod 100 < opacity, which spreads the kept
    -- rows evenly instead of drawing a solid block then a gap. Row parity is
    -- computed on absolute screen Y so the four bands stay in phase.
    ----------------------------------------------------------------------------
    fn rcm_fillRect x0 y0 x1 y1 clr =
    (
        local ix0 = x0 as integer
        local ix1 = x1 as integer
        local iy0 = y0 as integer
        local iy1 = y1 as integer
        local op  = RCM_opacity
        if op > 100 do op = 100
        if op < 1 do op = 1
        if ix1 > ix0 and iy1 > iy0 do
        (
            gw.setColor #line clr
            if op >= 100 then
            (
                for yy = iy0 to iy1 do
                    gw.wPolyline #([ix0, yy, 0], [ix1, yy, 0]) false
            )
            else
            (
                for yy = iy0 to iy1 where (mod (yy * op) 100) < op do
                    gw.wPolyline #([ix0, yy, 0], [ix1, yy, 0]) false
            )
        )
    )

    ----------------------------------------------------------------------------
    -- Rectangle outline.
    ----------------------------------------------------------------------------
    fn rcm_rectOutline x0 y0 x1 y1 clr =
    (
        gw.setColor #line clr
        gw.wPolyline #([x0,y0,0],[x1,y0,0],[x1,y1,0],[x0,y1,0]) true
    )

    ----------------------------------------------------------------------------
    -- Drawing function, called on every viewport redraw.
    ----------------------------------------------------------------------------
    fn rcm_draw =
    (
        if not RCM_active do return false

        local allowed = rcm_viewAllowed()
        rcm_syncSafeFrame allowed
        if not allowed do return false

        local f    = rcm_field()
        local ox   = f[1]; local oy   = f[2]
        local fx   = f[3]; local fy   = f[4]
        local winX = f[5]; local winY = f[6]

        -- Render frame (a square when you keep the render square)
        local X0 = ox;       local Y0 = oy
        local X1 = ox + fx;  local Y1 = oy + fy
        local frameA = fx / fy            -- aspect of the render frame (1.0 when 1:1)
        local a = RCM_aspect              -- target aspect W/H

        -- Target ratio rectangle, positioned inside the render frame.
        -- The offset acts on whichever axis has slack (depending on orientation/flip),
        -- expressed as a % of that slack: 0 = centred, -100 = against one edge,
        -- +100 = against the opposite edge.
        local ofs = RCM_offset / 100.0
        local cX0, cY0, cX1, cY1
        if a >= frameA then
        (
            -- ratio wider than the frame -> full width, vertical slack
            local ch = fx / a
            local slack = fy - ch
            cX0 = X0;  cX1 = X1
            cY0 = Y0 + slack / 2.0 * (1.0 + ofs)   -- ofs<0 up, ofs>0 down
            cY1 = cY0 + ch
        )
        else
        (
            -- ratio taller than the frame -> full height, horizontal slack
            local cw = fy * a
            local slack = fx - cw
            cY0 = Y0;  cY1 = Y1
            cX0 = X0 + slack / 2.0 * (1.0 + ofs)   -- ofs<0 left, ofs>0 right
            cX1 = cX0 + cw
        )

        -- 1) Matte: the whole viewport EXCEPT the target rectangle
        if RCM_showMask do
        (
            local mc = RCM_maskColor
            rcm_fillRect 0    0    winX cY0  mc      -- top band
            rcm_fillRect 0    cY1  winX winY mc      -- bottom band
            rcm_fillRect 0    cY0  cX0  cY1  mc      -- left band
            rcm_fillRect cX1  cY0  winX cY1  mc      -- right band
        )

        -- 2) Outline of the target ratio
        rcm_rectOutline cX0 cY0 cX1 cY1 RCM_cropColor

        -- 3) Rule of thirds inside the target ratio
        if RCM_showThirds do
        (
            gw.setColor #line RCM_cropColor
            local cw = cX1 - cX0
            local chh = cY1 - cY0
            for i = 1 to 2 do
            (
                local xx = cX0 + cw * i / 3.0
                gw.wPolyline #([xx,cY0,0],[xx,cY1,0]) false
                local yy = cY0 + chh * i / 3.0
                gw.wPolyline #([cX0,yy,0],[cX1,yy,0]) false
            )
        )

        -- 4) Ratio label (top left of the target frame)
        try ( gw.setColor #text RCM_cropColor; gw.wText [cX0 + 6, cY0 + 4, 0] RCM_label ) catch()

        gw.enlargeUpdateRect #whole
        gw.updateScreen()
        true
    )

    ----------------------------------------------------------------------------
    -- Callback (un)registration
    ----------------------------------------------------------------------------
    fn rcm_register   = ( unregisterRedrawViewsCallback rcm_draw; registerRedrawViewsCallback rcm_draw )
    fn rcm_unregister = ( unregisterRedrawViewsCallback rcm_draw; completeRedraw() )

    ----------------------------------------------------------------------------
    -- Interface
    ----------------------------------------------------------------------------
    rollout rcmRoll "Ratio Crop Mask" width:200 height:278
    (
        checkbutton ck_on        "  Enable overlay  "     pos:[8,8]   width:184 height:26  checked:false

        label       lb_ratio     "Ratio:"                 pos:[8,46]
        dropdownlist ddl_ratio    ""                       pos:[48,42] width:92
        button      btn_flip     "Flip"                   pos:[146,42] width:46 height:21

        spinner     spn_w        "W"  pos:[44,74]  width:54  range:[1,500,16] type:#integer \
                    tooltip:"Width of the Custom ratio (live only when 'Custom' is selected)."
        spinner     spn_h        "H"  pos:[110,74] width:54  range:[1,500,9]  type:#integer \
                    tooltip:"Height of the Custom ratio (live only when 'Custom' is selected)."

        spinner     spn_off      "Offset"  pos:[8,100] width:150 range:[-100,100,0] type:#integer \
                    tooltip:"Shifts the frame on the free axis (vertical in landscape, horizontal in portrait). Clamped to the 1:1 square."
        button      btn_off0     "C"  pos:[170,99] width:22 height:18  tooltip:"Recentre"

        checkbutton ck_mask      "Matte"              pos:[8,128]  width:140 height:22 checked:true
        colorPicker cp_mask      ""                   pos:[152,127] width:40 height:21 color:(color 12 12 12)

        spinner     spn_opa      "Opacity"  pos:[8,154] width:150 range:[5,100,100] type:#integer \
                    tooltip:"Matte density. No alpha in the viewport, so lower values simply draw fewer lines and let the image show through (screen door). 100 = solid."
        button      btn_opa100   "F"  pos:[170,153] width:22 height:18  tooltip:"Back to 100%"

        checkbutton ck_thirds    "Rule of thirds"     pos:[8,180]  width:140 height:22 checked:false
        colorPicker cp_crop      ""                   pos:[152,179] width:40 height:21 color:(color 255 255 255)

        checkbutton ck_safe      "Safe frame auto"    pos:[8,206]  width:184 height:22 checked:true \
                    tooltip:"On: the safe frame is turned on in the viewport the overlay draws in and off when you leave it (it is a global flag in Max, there is no per-viewport setting). Off: the tool never touches it, use Shift+F yourself."

        label       lb_info      "Ready."              pos:[8,236]  width:184 height:30

        ------------------------------------------------------------------
        fn refresh = ( if RCM_active do completeRedraw() )

        -- Reports Max's render lock, which is what pins the overlay to one view.
        fn lockText =
        (
            local t = ""
            try
            (
                if (not rendUseActiveView) and viewport.numViews > 1 do
                    t = "Locked to viewport " + rendViewIndex as string + "."
            )
            catch()
            t
        )

        fn pushState =
        (
            RCM_showMask   = ck_mask.checked
            RCM_showThirds = ck_thirds.checked
            RCM_maskColor  = cp_mask.color
            RCM_cropColor  = cp_crop.color
            RCM_offset     = spn_off.value as float
            RCM_opacity    = spn_opa.value
            RCM_sfAuto     = ck_safe.checked
            refresh()
        )

        fn setAspect a lbl =
        (
            RCM_aspect = a
            RCM_label  = lbl
            lb_info.text = "Active ratio: " + lbl + "   (W/H = " + (formattedPrint a format:".3f") + ")"
            refresh()
        )

        fn applyCustom =
        (
            local w = spn_w.value as float
            local h = spn_h.value as float
            if h > 0 do
                setAspect (w/h) ((spn_w.value as string) + ":" + (spn_h.value as string))
        )

        fn isCustom = ( ddl_ratio.selected == "Custom" )

        ------------------------------------------------------------------
        on ck_on changed st do
        (
            RCM_active = st
            if st then
            (
                pushState()
                rcm_register()
                -- Forget the last known viewport so the first redraw sets the
                -- safe frame for wherever we are right now.
                RCM_lastVP = -1
                completeRedraw()
                local lt = lockText()
                lb_info.text = if lt == "" then "Overlay on." else ("Overlay on. " + lt)
            )
            else
            (
                rcm_unregister()
                lb_info.text = "Overlay off."
            )
        )

        on ddl_ratio selected i do
        (
            if presetLabels[i] == "Custom" then applyCustom()
            else setAspect presetAspects[i] presetLabels[i]
        )

        on btn_flip pressed do
        (
            -- flips the orientation (16:9 <-> 9:16, 4:5 <-> 5:4, etc.)
            local na = 1.0 / RCM_aspect
            local found = 0
            for k = 1 to presetAspects.count while found == 0 do
                if presetLabels[k] != "Custom" and (abs (presetAspects[k] - na)) < 0.001 do found = k
            if found > 0 then
            (
                ddl_ratio.selection = found
                setAspect presetAspects[found] presetLabels[found]
            )
            else
            (
                -- no matching preset -> switch to Custom with W/H swapped
                local oldw = spn_w.value
                spn_w.value = spn_h.value
                spn_h.value = oldw
                ddl_ratio.selection = (findItem presetLabels "Custom")
                applyCustom()
            )
        )

        -- The W/H fields drive the ratio only while "Custom" is selected
        on spn_w changed v do ( if isCustom() do applyCustom() )
        on spn_h changed v do ( if isCustom() do applyCustom() )

        on spn_off   changed v  do ( RCM_offset = v as float; refresh() )
        on btn_off0  pressed    do ( spn_off.value = 0; RCM_offset = 0.0; refresh() )

        on spn_opa    changed v do ( RCM_opacity = v; refresh() )
        on btn_opa100 pressed   do ( spn_opa.value = 100; RCM_opacity = 100; refresh() )

        on ck_mask   changed st do pushState()
        on ck_thirds changed st do pushState()
        on cp_mask   changed c  do pushState()
        on cp_crop   changed c  do pushState()

        on ck_safe changed st do
        (
            RCM_sfAuto = st
            if st then
            (
                -- Take over again from wherever we are.
                RCM_lastVP = -1
                lb_info.text = "Safe frame follows the overlay."
                completeRedraw()
            )
            else
                lb_info.text = "Safe frame is yours (Shift+F). Without it the overlay is not aligned."
        )

        ------------------------------------------------------------------
        on rcmRoll open do
        (
            ddl_ratio.items = presetLabels
            ddl_ratio.selection = 2          -- 16:9 by default
            RCM_aspect = presetAspects[2]
            RCM_label  = presetLabels[2]
            pushState()
            lb_info.text = "Tick 'Enable overlay'."
        )

        on rcmRoll close do
        (
            RCM_active = false
            rcm_unregister()
        )
    )

    ----------------------------------------------------------------------------
    -- GLOBAL ENTRY POINT
    -- Exposes opening the window so that the macroScript (toolbar button /
    -- keyboard shortcut) can call it without reloading the file.
    ----------------------------------------------------------------------------
    fn aioli_ratiomask_open =
    (
        try (destroyDialog rcmRoll) catch()
        createDialog rcmRoll style:#(#style_titlebar, #style_border, #style_sysmenu)
    )
)

------------------------------------------------------------------------
-- MACROSCRIPT REGISTRATION
-- Creates the "ratiomask" entry in the "aiolicollective" category of
-- Customize > Customize User Interface. Evaluating this block is enough:
-- 3ds Max writes the matching .mcr into its usermacros folder itself, so
-- the entry stays available on the next startups.
--
-- THE PATH TO THIS FILE IS BAKED INTO THE MACRO at drag & drop time, the
-- same way aioli-sunpos and aioli-clonelayers do it. The macro stays a thin
-- launcher instead of carrying a copy of the code, so the toolbar button
-- follows git pull. Move the folder and you just drag the .ms in again.
------------------------------------------------------------------------
(
    local thisFile = ""
    try (thisFile = getSourceFileName()) catch()
    if thisFile == undefined do thisFile = ""

    -- Evaluated from the Listener rather than from a file: fall back to the
    -- documented install location.
    if thisFile == "" do
        thisFile = (getDir #userScripts) + "\\aioli\\ratiomask\\aioli-ratiomask.ms"

    local src = ""
    src += "macroScript aioli_ratiomask category:\"aiolicollective\" buttonText:\"ratiomask\" "
    src += "toolTip:\"aioli-ratiomask - viewport crop-ratio matte\"\n"
    src += "(\n"
    src += "    on execute do\n"
    src += "    (\n"
    src += "        if aioli_ratiomask_open != undefined then\n"
    src += "            aioli_ratiomask_open()\n"
    src += "        else\n"
    src += "        (\n"
    src += "            -- Not loaded yet in this session of Max: read the file\n"
    src += "            -- again. Running it re-registers the macro and opens\n"
    src += "            -- the window, so edits pulled from git apply at once.\n"
    src += "            local p = @\"" + thisFile + "\"\n"
    src += "            if doesFileExist p then\n"
    src += "                fileIn p\n"
    src += "            else\n"
    src += "                messageBox (\"Script not found:\\n\" + p + \"\\n\\n\" + \\\n"
    src += "                            \"Did the folder move? \" + \\\n"
    src += "                            \"Drag aioli-ratiomask.ms into 3ds Max again.\") \\\n"
    src += "                           title:\"aioli-ratiomask\"\n"
    src += "        )\n"
    src += "    )\n"
    src += ")\n"
    execute src

    format "[aioli-ratiomask] macro \"ratiomask\" registered (category \"aiolicollective\")\n"
    format "[aioli-ratiomask] script : %\n" thisFile
    format "[aioli-ratiomask] button : Customize > Customize User Interface > Toolbars > Category \"aiolicollective\"\n"
)

------------------------------------------------------------------------
-- LAUNCH
-- Run Script only DEFINES a macroScript, it does not run it: opening the
-- panel here is what makes drag & drop behave like the other two tools.
------------------------------------------------------------------------
aioli_ratiomask_open()
