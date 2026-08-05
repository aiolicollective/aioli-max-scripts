/***************************************************************************************
    aioli-ratiomask  (Aioli Ratio Mask)  -  v1.0
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

    INSTALLATION :
      Scripting > Run Script... (or drag the .ms into the viewport).
      A "Ratio Crop Mask" window opens. Tick "Enable overlay".
      (Optional) For a permanent button: Customize > Customize User Interface >
      category "aioli" > macro "ratiomask", drag it onto a toolbar.

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
    global RCM_showThirds  = false
    global RCM_showFrame   = true                -- outline of the render frame (1:1)
    global RCM_frameColor  = (color 255 220 0)   -- render frame outline colour
    global RCM_cropColor   = (color 255 255 255) -- ratio outline + thirds colour
    global RCM_offset      = 0.0                  -- frame offset on the free axis (-100..100)

    ----------------------------------------------------------------------------
    -- Ratio presets :  label  ->  aspect (W/H)
    ----------------------------------------------------------------------------
    local presetLabels  = #("1:1","16:9","9:16","4:5","5:4","3:2","2:3","4:3","3:4","2:1","1:2","1.85:1","2.39:1","Custom")
    local presetAspects = #( 1.0, (16.0/9.0), (9.0/16.0), (4.0/5.0), (5.0/4.0), (3.0/2.0), (2.0/3.0), (4.0/3.0), (3.0/4.0), 2.0, 0.5, 1.85, 2.39, 1.0 )

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
    -- Filled rectangle (opaque matte) in screen coordinates.
    ----------------------------------------------------------------------------
    fn rcm_fillRect x0 y0 x1 y1 clr =
    (
        -- Reliable fill: tightly packed horizontal lines (1 px).
        -- gw.wPolyline is the only primitive that is really stable in Nitrous.
        local ix0 = x0 as integer
        local ix1 = x1 as integer
        local iy0 = y0 as integer
        local iy1 = y1 as integer
        if ix1 > ix0 and iy1 > iy0 do
        (
            gw.setColor #line clr
            for yy = iy0 to iy1 do
                gw.wPolyline #([ix0, yy, 0], [ix1, yy, 0]) false
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

        -- 2) Outline of the render frame (1:1)
        if RCM_showFrame do rcm_rectOutline X0 Y0 X1 Y1 RCM_frameColor

        -- 3) Outline of the target ratio
        rcm_rectOutline cX0 cY0 cX1 cY1 RCM_cropColor

        -- 4) Rule of thirds inside the target ratio
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

        -- 5) Ratio label (top left of the target frame)
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

        checkbutton ck_frame     "Render frame (1:1)" pos:[8,154]  width:140 height:22 checked:true
        colorPicker cp_frame     ""                   pos:[152,153] width:40 height:21 color:(color 255 220 0)

        checkbutton ck_thirds    "Rule of thirds"     pos:[8,180]  width:140 height:22 checked:false
        colorPicker cp_crop      ""                   pos:[152,179] width:40 height:21 color:(color 255 255 255)

        checkbutton ck_safe      "Max safe frame"     pos:[8,206]  width:184 height:22 checked:false

        label       lb_info      "Ready."              pos:[8,236]  width:184 height:30

        ------------------------------------------------------------------
        fn refresh = ( if RCM_active do completeRedraw() )

        fn pushState =
        (
            RCM_showMask   = ck_mask.checked
            RCM_showFrame  = ck_frame.checked
            RCM_showThirds = ck_thirds.checked
            RCM_maskColor  = cp_mask.color
            RCM_frameColor = cp_frame.color
            RCM_cropColor  = cp_crop.color
            RCM_offset     = spn_off.value as float
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
                -- Safe frame required: the overlay lines up with the render area,
                -- which Max only displays properly when the safe frame is on.
                displaySafeFrames = true
                ck_safe.checked = true
                completeRedraw()
                lb_info.text = "Overlay on (safe frame ON)."
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

        on ck_mask   changed st do pushState()
        on ck_frame  changed st do pushState()
        on ck_thirds changed st do pushState()
        on cp_mask   changed c  do pushState()
        on cp_frame  changed c  do pushState()
        on cp_crop   changed c  do pushState()

        on ck_safe changed st do
        (
            displaySafeFrames = st
            if RCM_active and (not st) then
                lb_info.text = "Careful: without the safe frame the overlay is no longer aligned."
            else if st then
                lb_info.text = "Safe frame ON."
            else
                lb_info.text = "Safe frame OFF."
            completeRedraw()
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
-- Creates the "ratiomask" entry in the "aioli" category of
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
    src += "macroScript aioli_ratiomask category:\"aioli\" buttonText:\"ratiomask\" "
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

    format "[aioli-ratiomask] macro \"ratiomask\" registered (category \"aioli\")\n"
    format "[aioli-ratiomask] script : %\n" thisFile
    format "[aioli-ratiomask] button : Customize > Customize User Interface > Toolbars > Category \"aioli\"\n"
)

------------------------------------------------------------------------
-- LAUNCH
-- Run Script only DEFINES a macroScript, it does not run it: opening the
-- panel here is what makes drag & drop behave like the other two tools.
------------------------------------------------------------------------
aioli_ratiomask_open()
