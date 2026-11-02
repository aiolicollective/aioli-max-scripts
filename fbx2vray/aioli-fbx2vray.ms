/*-----------------------------------------------------------------------------
	aioli-fbx2vray
	-----------------------------------------------------------------------------
	Imports an FBX and rebuilds its exact V-Ray materials and lights from the
	<name>_vray.json written next to it (our Blender-side exporter reads the
	V-Ray for Blender node graphs; the FBX cannot carry them). Works on an
	FBX imported earlier too: the materials are found by their name.

	Author   : /ai.oli collective
	Version  : 1.0 (in test)
	Compat.  : 3ds Max 2022+ (Python 3, pymxs) with V-Ray 5+. Written for
	           3ds Max 2026 / V-Ray 7.
	Usage    : Scripting > Run Script, or drag & drop into 3ds Max. The script
	           registers itself in Customize User Interface, category
	           "aiolicollective", action "fbx2vray".

	IMPORT FBX...      with a <name>_vray.json next to the FBX: import, then
	                   V-Ray materials and lights from the file. Without one:
	                   import, the new objects selected, phys2vray opened
	                   (CONVERT TO V-RAY, generic Physical -> VRayMtl).
	APPLY .JSON...     the file's materials replace those of the same name on
	                   the selection and its children (nothing selected: the
	                   whole scene, after a question).
	A V-Ray material with the same name already in the scene: ask (a window
	lists them), reuse it, or rebuild it from the file everywhere it is used.
	Materials and lights in a single undo. Details in the Listener (F11).

	This file is the panel and the launcher; the work is in fbx2vray.py, next
	to it, run again at every click (a git pull applies at once). The file
	format is in FORMAT.md.
-----------------------------------------------------------------------------*/

global aioli_roFbx2Vray        -- the tool window
global aioli_roFbx2VrayAsk     -- the question about existing V-Ray materials
global aioli_fbx2vray_open     -- entry point called by the macroScript
global aioli_fbx2vray_ask      -- called from fbx2vray.py: "reuse" / "rebuild" / "cancel"
global aioli_fbx2vray_request  -- set by the panel, read by fbx2vray.py, cleared after the run
global aioli_fbx2vray_askItems
global aioli_fbx2vray_answer

(
	------------------------------------------------------------------------
	-- CONSTANTS
	------------------------------------------------------------------------
	local iniFile = (getDir #plugcfg) + "\\aioli-fbx2vray.ini"
	local thisFile = ""
	try (thisFile = getSourceFileName()) catch()
	if thisFile == undefined do thisFile = ""
	local toolDir = getFilenamePath thisFile
	local pyFile = toolDir + "fbx2vray.py"

	------------------------------------------------------------------------
	-- QUESTION: V-Ray materials of the same name already in the scene
	-- (modal; the answer goes through a global because a modal dialog
	--  cannot return a value)
	------------------------------------------------------------------------
	rollout aioli_roFbx2VrayAsk "aioli-fbx2vray" width:380
	(
		label lbTitle "" align:#left width:356
		listbox lstNames "" height:10
		label lbReuse "Reuse: they stay as they are and go on the new objects." align:#left
		label lbRebuild "Rebuild: made again from the .json, everywhere they are used." align:#left
		label lbCancel "Cancel: nothing changes (with IMPORT, nothing is imported)." align:#left
		button btnReuse "REUSE" width:112 height:28 across:3
		button btnRebuild "REBUILD FROM .JSON" width:112 height:28
		button btnCancel "CANCEL" width:112 height:28

		on aioli_roFbx2VrayAsk open do
		(
			lstNames.items = aioli_fbx2vray_askItems
			lbTitle.text = (aioli_fbx2vray_askItems.count as string) + \
				" V-Ray material(s) of the .json already in the scene:"
		)
		on btnReuse pressed do (aioli_fbx2vray_answer = "reuse"; destroyDialog aioli_roFbx2VrayAsk)
		on btnRebuild pressed do (aioli_fbx2vray_answer = "rebuild"; destroyDialog aioli_roFbx2VrayAsk)
		on btnCancel pressed do (aioli_fbx2vray_answer = "cancel"; destroyDialog aioli_roFbx2VrayAsk)
	)

	fn aioli_fbx2vray_ask namesText n =
	(
		aioli_fbx2vray_answer = "cancel"     -- closing the window = cancel
		aioli_fbx2vray_askItems = filterString namesText "\n"
		try (destroyDialog aioli_roFbx2VrayAsk) catch()
		createDialog aioli_roFbx2VrayAsk modal:true
		aioli_fbx2vray_answer
	)

	------------------------------------------------------------------------
	-- PANEL
	------------------------------------------------------------------------
	rollout aioli_roFbx2Vray "aioli-fbx2vray 1.0" width:300
	(
		group "FBX + _vray.json"
		(
			button btnImport "IMPORT FBX..." width:272 height:30 \
				tooltip:"Imports an FBX. With its <name>_vray.json next to it: V-Ray materials and lights\nrebuilt from the file. Without: the FBX alone, its objects selected, phys2vray opened."
			button btnApply "APPLY .JSON TO SELECTION..." width:272 height:30 \
				tooltip:"For an FBX already in the scene: the materials of a _vray.json replace those\nof the same name on the selection and its children (nothing selected: the whole scene)."
		)
		group "Options"
		(
			label lbExisting "Same-name V-Ray material in the scene:" align:#left width:272
			dropdownList ddExisting "" items:#("Ask", "Reuse it", "Rebuild it from the .json") width:272
			checkbox chkLights "Create the lights of the .json" checked:true
		)
		label lbLog "Details in the MAXScript Listener (F11)." align:#left

		fn saveIni =
		(
			setINISetting iniFile "options" "existing" (ddExisting.selection as string)
			setINISetting iniFile "options" "lights" (chkLights.checked as string)
		)

		fn run action =
		(
			if not (doesFileExist pyFile) then
				messageBox ("fbx2vray.py was not found next to this script.\n\nExpected here:\n" + pyFile + \
					"\n\nKeep aioli-fbx2vray.ms in the same folder as fbx2vray.py.") title:"aioli-fbx2vray"
			else
			(
				local existing = #("ask", "reuse", "rebuild")[ddExisting.selection]
				aioli_fbx2vray_request = "action=" + action + "\nexisting=" + existing + \
					"\nlights=" + (if chkLights.checked then "1" else "0") + "\nhere=" + toolDir
				try (python.ExecuteFile pyFile)
				catch (format "[aioli-fbx2vray] %\n" (getCurrentException()))
				aioli_fbx2vray_request = undefined
			)
		)

		on aioli_roFbx2Vray open do
		(
			local v = getINISetting iniFile "options" "existing"
			local i = if v != "" then (v as integer) else undefined
			if i != undefined and i >= 1 and i <= 3 do ddExisting.selection = i
			v = getINISetting iniFile "options" "lights"
			if v != "" do chkLights.checked = (v == "true")
		)
		on ddExisting selected i do saveIni()
		on chkLights changed state do saveIni()
		on btnImport pressed do run "import"
		on btnApply pressed do run "apply"
	)

	------------------------------------------------------------------------
	-- GLOBAL ENTRY POINT
	------------------------------------------------------------------------
	fn aioli_fbx2vray_open =
	(
		try (destroyDialog aioli_roFbx2Vray) catch()
		createDialog aioli_roFbx2Vray
	)
)

------------------------------------------------------------------------
-- MACROSCRIPT REGISTRATION
-- Same launcher as phys2vray: the path to this file is baked into the
-- macro when it is dragged in, and the file is read again at EVERY click,
-- so a git pull applies at the next click without restarting 3ds Max.
-- Move the folder and you just drag the .ms in again.
------------------------------------------------------------------------
(
	local thisFile = ""
	try (thisFile = getSourceFileName()) catch()
	if thisFile == undefined do thisFile = ""

	-- Evaluated from the Listener rather than from a file: fall back to the
	-- documented install location.
	if thisFile == "" do
		thisFile = (getDir #userScripts) + "\\aioli\\fbx2vray\\aioli-fbx2vray.ms"

	local src = ""
	src += "macroScript aioli_fbx2vray category:\"aiolicollective\" buttonText:\"fbx2vray\" "
	src += "toolTip:\"aioli-fbx2vray - FBX + _vray.json -> exact V-Ray materials and lights\"\n"
	src += "(\n"
	src += "    on execute do\n"
	src += "    (\n"
	src += "        -- The file is read again at every click: a git pull applies\n"
	src += "        -- at once, without restarting 3ds Max.\n"
	src += "        local p = @\"" + thisFile + "\"\n"
	src += "        if doesFileExist p then\n"
	src += "            fileIn p\n"
	src += "        else\n"
	src += "        (\n"
	src += "            messageBox (\"Script not found:\\n\" + p + \"\\n\\n\" + \\\n"
	src += "                        \"Did the folder move? \" + \\\n"
	src += "                        \"Drag aioli-fbx2vray.ms into 3ds Max again.\") \\\n"
	src += "                       title:\"aioli-fbx2vray\"\n"
	src += "            if aioli_fbx2vray_open != undefined do aioli_fbx2vray_open()\n"
	src += "        )\n"
	src += "    )\n"
	src += ")\n"
	execute src

	format "[aioli-fbx2vray] macro \"fbx2vray\" registered (category \"aiolicollective\")\n"
	format "[aioli-fbx2vray] script : %\n" thisFile
	format "[aioli-fbx2vray] button : Customize > Customize User Interface > Toolbars > Category \"aiolicollective\"\n"
)

------------------------------------------------------------------------
-- LAUNCH
------------------------------------------------------------------------
aioli_fbx2vray_open()
