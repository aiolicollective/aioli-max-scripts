/*-----------------------------------------------------------------------------
	aioli-clonelayers
	-----------------------------------------------------------------------------
	Clones the current selection and rebuilds the full layer / sub-layer tree
	of the sources, with a configurable prefix / suffix and clone mode.

	Author   : /ai.oli collective
	Version  : 1.0
	Compat.  : 3ds Max 2016 -> 2026+ (layermanager / maxOps.cloneNodes API)
	Usage    : Scripting > Run Script. The script registers itself in
	           Customize User Interface, category "aioli", action
	           "clonelayers" (toolbar, menu, quad or keyboard shortcut).

	Based on an original script that only walked up one level of parent.
-----------------------------------------------------------------------------*/

global aioli_roCloneLayers      -- the tool window
global aioli_clonelayers_open   -- entry point called by the macroScript

(
	------------------------------------------------------------------------
	-- CONSTANTS
	------------------------------------------------------------------------
	local iniFile = (getDir #plugcfg) + "\\aioli-clonelayers.ini"
	local cloneTypes = #(#copy, #instance, #reference)

	-- Layer properties that get copied (try/catch: some of them do not exist
	-- on every version of Max, we ignore those silently)
	local layerPropsToCopy = #(
		#wireColor, #renderable, #boxmode, #allEdges, #vertexTicks,
		#trajectory, #ignoreExtents, #showFrozenInGray, #backFaceCull,
		#applyAtmospherics, #castShadows, #receiveShadows, #xrayMtl,
		#displayByLayer, #renderByLayer, #motionBlurByLayer
	)

	------------------------------------------------------------------------
	-- ROLLOUT
	-- (declared global at the top of the file: scene callbacks are evaluated
	--  in global scope and must be able to find the window by its name)
	------------------------------------------------------------------------
	rollout aioli_roCloneLayers "aioli-clonelayers" width:300
	(
		-- Lookup table, source layer -> target layer
		local mapSrcNames = #()
		local mapDstLayers = #()

		-- Layer where walking up the tree stops
		-- (lowest common ancestor of every source layer)
		local stopLayerName = ""

		-- Step shared by the whole batch in "trailing number" mode
		local batchStep = 1

		----------------------------------------------------------------
		-- UI
		----------------------------------------------------------------
		group "Naming"
		(
			radiobuttons rdoNameMode labels:#("Prefix / suffix", "Increment trailing number") default:1 columns:1
			edittext edtPrefix "Prefix  :" text:"" fieldWidth:200 offset:[8,0]
			edittext edtSuffix "Suffix  :" text:"_LP" fieldWidth:200 offset:[8,0]
			label lblNumInfo "" height:26 width:270 align:#left
			checkbox chkNameLayers "Apply to layers" checked:true
			checkbox chkNameObjects "Apply to objects" checked:true
			checkbox chkUniqueNames "Avoid duplicate object names" checked:true
		)

		group "Clone mode"
		(
			radiobuttons rdoClone labels:#("Copy", "Instance", "Reference") default:1 columns:3
			label lblCloneInfo "" height:26 width:270 align:#left
		)

		group "Options"
		(
			checkbox chkCopyProps "Copy layer properties" checked:true
			checkbox chkForceVisible "Force new layers visible / unfrozen" checked:false
			checkbox chkExpand "Include linked children (object hierarchy)" checked:false
			checkbox chkSelectNew "Select the clones when done" checked:true
		)

		label lblStatus "Selected: 0 object(s)" align:#left
		button btnGo "CLONE" width:280 height:30

		----------------------------------------------------------------
		-- HELPERS
		----------------------------------------------------------------

		-- Splits a name into #(base, trailing digits).
		-- "Floor_001" -> #("Floor_", "001")   "Floor001" -> #("Floor", "001")
		-- A name with no trailing digits is treated as if it carried the
		-- implicit number 001: "Floor" -> #("Floor_", "001")
		fn numParts nm =
		(
			local i = nm.count

			while i >= 1 and (bit.charAsInt nm[i]) >= 48 and (bit.charAsInt nm[i]) <= 57 do i -= 1

			if i == nm.count then
				#(nm + "_", "001")                                  -- no number
			else
				#((substring nm 1 i), (substring nm (i + 1) -1))    -- number found
		)

		-- Left-pads with zeros up to the original width
		fn padNum n width =
		(
			local s = n as string
			while s.count < width do s = "0" + s
			s
		)

		-- Name incremented by k steps
		fn incName parts k =
		(
			parts[1] + (padNum ((parts[2] as integer) + k) parts[2].count)
		)

		-- Looks for the smallest shared step for which EVERY layer of the
		-- batch gets a free name. Guarantees a consistent set: we do not want
		-- Floor_002 next to Walls_004 just because Walls_002 was taken.
		fn findBatchStep srcNames =
		(
			local k = 1

			while k <= 999 do
			(
				local allFree = true

				for nm in srcNames while allFree do
				(
					if (layermanager.getLayerFromName (incName (numParts nm) k)) != undefined do
						allFree = false
				)

				if allFree do return k
				k += 1
			)
			1
		)

		-- Target name for a source layer
		fn buildLayerName srcName =
		(
			if not chkNameLayers.checked do return srcName

			if rdoNameMode.state == 2 then
				(incName (numParts srcName) batchStep)
			else
				(edtPrefix.text + srcName + edtSuffix.text)
		)

		-- Target name for a source object
		fn buildObjectName srcName =
		(
			if rdoNameMode.state == 2 then
				(incName (numParts srcName) batchStep)
			else
				(edtPrefix.text + srcName + edtSuffix.text)
		)

		-- Ancestor chain of a layer, from the scene root down to the layer
		-- itself. #("Project", "Building", "Floor_01")
		fn ancestorChain lyr =
		(
			local up = #()
			local l = lyr

			while l != undefined do
			(
				append up l.name
				l = l.getParent()
			)

			local chain = #()
			for i = up.count to 1 by -1 do append chain up[i]
			chain
		)

		-- Lowest common ancestor of every source layer: the smallest subtree
		-- that contains them all. That is where the rebuild stops, which
		-- preserves the intermediate grouping layers even when they hold no
		-- object of their own.
		-- Returns "" when the source layers sit in disjoint branches (no
		-- common ancestor): we then walk all the way up to the root.
		fn findCommonRoot srcNames =
		(
			local chains = #()

			for nm in srcNames do
			(
				local l = layermanager.getLayerFromName nm
				if l != undefined do append chains (ancestorChain l)
			)

			if chains.count == 0 do return ""

			-- longest common prefix of every chain
			local common = chains[1]

			for c in chains do
			(
				local n = amin common.count c.count
				local k = 0

				while k < n and common[k + 1] == c[k + 1] do k += 1

				common = for i = 1 to k collect common[i]
			)

			if common.count == 0 then "" else common[common.count]
		)

		-- Copies the display / render properties of a layer
		fn copyLayerProps src dst =
		(
			if src == undefined or dst == undefined do return false

			if chkCopyProps.checked do
			(
				for p in layerPropsToCopy do
				(
					try (setProperty dst p (getProperty src p)) catch()
				)
			)

			-- Visible / frozen state
			if chkForceVisible.checked then
			(
				try (dst.on = true) catch()
				try (dst.isHidden = false) catch()
				try (dst.isFrozen = false) catch()
			)
			else if chkCopyProps.checked do
			(
				try (dst.on = src.on) catch()
				try (dst.isHidden = src.isHidden) catch()
				try (dst.isFrozen = src.isFrozen) catch()
			)
			true
		)

		-- Returns (creating it when needed) the mirror layer of srcLayer,
		-- walking RECURSIVELY up the whole chain of parents.
		fn mapLayer srcLayer =
		(
			if srcLayer == undefined do return undefined

			-- already handled?
			local idx = findItem mapSrcNames srcLayer.name
			if idx > 0 do return mapDstLayers[idx]

			local newName = buildLayerName srcLayer.name
			local dstLayer = layermanager.getLayerFromName newName
			local created = false

			if dstLayer == undefined do
			(
				dstLayer = layermanager.newLayerFromName newName
				created = true
			)

			if dstLayer == undefined do return undefined  -- invalid name / conflict

			if created do copyLayerProps srcLayer dstLayer

			-- recorded BEFORE the recursion (guards against infinite loops)
			append mapSrcNames srcLayer.name
			append mapDstLayers dstLayer

			-- STOP WALKING UP: this layer is the lowest common ancestor of the
			-- batch. Nothing above it gets cloned: the new tree starts here,
			-- at the root of the scene.
			if srcLayer.name == stopLayerName do
				return dstLayer

			-- recursive walk up the tree
			local srcParent = srcLayer.getParent()
			if srcParent != undefined do
			(
				local dstParent = mapLayer srcParent

				-- SAFETY: an EXISTING layer is only reparented when it currently
				-- sits at the root. Otherwise a second run of the script would
				-- move a layer the user had filed by hand.
				local mayReparent = created or (dstLayer.getParent() == undefined)

				if mayReparent and dstParent != undefined and dstParent != dstLayer do
				(
					try (dstLayer.setParent dstParent) catch()
				)
			)

			dstLayer
		)

		----------------------------------------------------------------
		-- MAIN PROCESS
		----------------------------------------------------------------
		fn doClone =
		(
			local selObjs = getCurrentSelection()

			if selObjs.count == 0 do
			(
				messageBox "No object selected." title:"aioli-clonelayers"
				return false
			)

			-- Guard: renaming the layers with neither a prefix nor a suffix
			-- would amount to cloning into the source layers themselves.
			if rdoNameMode.state == 1 and chkNameLayers.checked and \
				edtPrefix.text == "" and edtSuffix.text == "" do
			(
				local q = queryBox "No prefix and no suffix: the clones will be placed in the source layers.\n\nContinue?" \
					title:"aioli-clonelayers"
				if not q do return false
			)

			-- reset the lookup table
			mapSrcNames = #()
			mapDstLayers = #()
			stopLayerName = ""
			batchStep = 1

			local cloneType = cloneTypes[rdoClone.state]
			local newNodes = #()
			local actualNodes = #()
			local orphans = 0

			local prevLayer = layermanager.current

			disableSceneRedraw()

			try
			(
				undo "aioli-clonelayers" on
				(
					maxOps.cloneNodes selObjs \
						cloneType:cloneType \
						offset:[0,0,0] \
						expandHierarchy:chkExpand.checked \
						actualNodeList:&actualNodes \
						newNodes:&newNodes

					----------------------------------------------------
					-- BATCH ANALYSIS (before any layer gets created)
					----------------------------------------------------

					-- Source layers actually involved
					local srcLayerNames = #()
					for n in actualNodes do
					(
						if isValidNode n do
						(
							local ln = n.layer.name
							if (findItem srcLayerNames ln) == 0 do append srcLayerNames ln
						)
					)

					-- Lowest common ancestor: upper bound of the rebuild.
					-- This is what keeps the intermediate grouping layers even
					-- when they hold no object of their own.
					stopLayerName = findCommonRoot srcLayerNames

					-- Every layer that will be recreated: the source layers AND
					-- the intermediate groupings up to and including the common
					-- ancestor. Used to work out the shared step.
					local allLayerNames = #()

					for ln in srcLayerNames do
					(
						local l = layermanager.getLayerFromName ln

						while l != undefined do
						(
							if (findItem allLayerNames l.name) == 0 do append allLayerNames l.name
							l = if l.name == stopLayerName then undefined else l.getParent()
						)
					)

					-- Shared step in "trailing number" mode
					if rdoNameMode.state == 2 do
						batchStep = findBatchStep allLayerNames

					----------------------------------------------------
					-- FILING THE CLONES
					----------------------------------------------------
					for i = 1 to actualNodes.count do
					(
						local srcNode = actualNodes[i]
						local newNode = newNodes[i]

						if isValidNode srcNode and isValidNode newNode do
						(
							-- rename the object
							if chkNameObjects.checked do
							(
								local wantedName = buildObjectName srcNode.name

								-- We only disambiguate on an ACTUAL collision:
								-- names stay clean for as long as possible.
								-- (duplicates do not bother instances, but they
								--  break $node, FBX/USD exports and XRefs)
								if chkUniqueNames.checked do
								(
									try
									(
										if (getNodeByName wantedName exact:true) != undefined do
											wantedName = uniqueName wantedName
									)
									catch()
								)

								try (newNode.name = wantedName) catch()
							)

							-- put it in the mirror layer
							local srcLayer = srcNode.layer
							local dstLayer = if chkNameLayers.checked then (mapLayer srcLayer) else srcLayer
							local ok = false

							if dstLayer != undefined do
							(
								try (ok = (dstLayer.addNode newNode) != false) catch(ok = false)
							)

							if not ok do orphans += 1
						)
					)
				)
			)
			catch
			(
				enableSceneRedraw()
				messageBox ("Error while cloning:\n\n" + (getCurrentException())) title:"aioli-clonelayers"
				return false
			)

			enableSceneRedraw()
			try (prevLayer.current = true) catch()

			if chkSelectNew.checked then select newNodes else clearSelection()

			completeRedraw()

			local msg = (newNodes.count as string) + " object(s) cloned - " + \
				(mapDstLayers.count as string) + " layer(s) created/reused"
			if orphans > 0 do msg += " - " + (orphans as string) + " not filed (!)"

			lblStatus.text = msg
			format "[aioli-clonelayers] %\n" msg

			true
		)

		----------------------------------------------------------------
		-- SETTINGS PERSISTENCE
		----------------------------------------------------------------
		fn saveSettings =
		(
			try
			(
				setINISetting iniFile "Settings" "Prefix" edtPrefix.text
				setINISetting iniFile "Settings" "Suffix" edtSuffix.text
				setINISetting iniFile "Settings" "NameLayers" (chkNameLayers.checked as string)
				setINISetting iniFile "Settings" "NameObjects" (chkNameObjects.checked as string)
				setINISetting iniFile "Settings" "UniqueNames" (chkUniqueNames.checked as string)
				setINISetting iniFile "Settings" "CloneType" (rdoClone.state as string)
				setINISetting iniFile "Settings" "CopyProps" (chkCopyProps.checked as string)
				setINISetting iniFile "Settings" "ForceVisible" (chkForceVisible.checked as string)
				setINISetting iniFile "Settings" "Expand" (chkExpand.checked as string)
				setINISetting iniFile "Settings" "SelectNew" (chkSelectNew.checked as string)
				setINISetting iniFile "Settings" "NameMode" (rdoNameMode.state as string)
			)
			catch()
		)

		fn loadSettings =
		(
			try
			(
				if doesFileExist iniFile do
				(
					local v
					v = getINISetting iniFile "Settings" "Prefix"; edtPrefix.text = v
					v = getINISetting iniFile "Settings" "Suffix"; if v != "" do edtSuffix.text = v
					v = getINISetting iniFile "Settings" "NameLayers"; if v != "" do chkNameLayers.checked = (v == "true")
					v = getINISetting iniFile "Settings" "NameObjects"; if v != "" do chkNameObjects.checked = (v == "true")
					v = getINISetting iniFile "Settings" "UniqueNames"; if v != "" do chkUniqueNames.checked = (v == "true")
					v = getINISetting iniFile "Settings" "CloneType"; if v != "" do rdoClone.state = (v as integer)
					v = getINISetting iniFile "Settings" "CopyProps"; if v != "" do chkCopyProps.checked = (v == "true")
					v = getINISetting iniFile "Settings" "ForceVisible"; if v != "" do chkForceVisible.checked = (v == "true")
					v = getINISetting iniFile "Settings" "Expand"; if v != "" do chkExpand.checked = (v == "true")
					v = getINISetting iniFile "Settings" "SelectNew"; if v != "" do chkSelectNew.checked = (v == "true")
					v = getINISetting iniFile "Settings" "NameMode"; if v != "" do rdoNameMode.state = (v as integer)
				)
			)
			catch()
		)

		----------------------------------------------------------------
		-- HANDLERS
		----------------------------------------------------------------
		fn updateCloneInfo =
		(
			lblCloneInfo.text = case rdoClone.state of
			(
				1: "Independent copy: no link with the original."
				2: "Instance: any edit propagates both ways."
				3: "Reference: the base is shared, modifiers added\nabove stay local to the clone."
				default: ""
			)
		)

		fn updateStatus =
		(
			local n = selection.count
			lblStatus.text = "Selected: " + (n as string) + " object(s)"
			btnGo.enabled = (n > 0)
		)

		fn updateNameMode =
		(
			local numMode = (rdoNameMode.state == 2)

			edtPrefix.enabled = not numMode
			edtSuffix.enabled = not numMode

			lblNumInfo.text = if numMode then
				"Trailing number is incremented: Floor_001 > Floor_002.\nWith no number, _002 is appended. Step shared by the batch."
			else
				""
		)

		on rdoClone changed s do updateCloneInfo()
		on rdoNameMode changed s do updateNameMode()

		on btnGo pressed do
		(
			doClone()
			saveSettings()
		)

		on aioli_roCloneLayers open do
		(
			loadSettings()
			updateCloneInfo()
			updateNameMode()
			updateStatus()
			callbacks.addScript #selectionSetChanged \
				"try(aioli_roCloneLayers.lblStatus.text = \"Selected: \" + (selection.count as string) + \" object(s)\"; aioli_roCloneLayers.btnGo.enabled = (selection.count > 0))catch()" \
				id:#aioli_clonelayers
		)

		on aioli_roCloneLayers close do
		(
			saveSettings()
			callbacks.removeScripts id:#aioli_clonelayers
		)
	)

	------------------------------------------------------------------------
	-- GLOBAL ENTRY POINT
	-- Exposes opening the window so that the macroScript (toolbar button /
	-- keyboard shortcut) can call it without reloading the file.
	------------------------------------------------------------------------
	fn aioli_clonelayers_open =
	(
		try (destroyDialog aioli_roCloneLayers) catch()
		try (callbacks.removeScripts id:#aioli_clonelayers) catch()
		createDialog aioli_roCloneLayers
	)
)

------------------------------------------------------------------------
-- MACROSCRIPT REGISTRATION
-- Creates the "clonelayers" entry in the "aioli" category of
-- Customize > Customize User Interface (Toolbars, Menus, Quads and
-- Keyboard tabs). Evaluating this block is enough: 3ds Max writes the
-- matching .mcr into its usermacros folder itself, so the entry stays
-- available on the next startups.
------------------------------------------------------------------------
macroScript aioli_clonelayers
	category:"aioli"
	buttonText:"clonelayers"
	toolTip:"aioli-clonelayers - clone and rebuild the layer tree"
(
	on execute do
	(
		if aioli_clonelayers_open != undefined then
			aioli_clonelayers_open()
		else
		(
			-- The script has not been loaded yet in this session of Max.
			-- This path is where the repo is meant to be cloned, so that the
			-- toolbar button keeps working after a restart AND still follows
			-- git pull. See the README.
			local p = (getDir #userScripts) + "\\aioli\\clonelayers\\aioli-clonelayers.ms"

			if doesFileExist p then
				fileIn p
			else
				messageBox ("Script not found:\n\n" + p + \
					"\n\nClone aioli-max-scripts into that folder,\n" + \
					"or run the script once through Scripting > Run Script.") \
					title:"aioli-clonelayers"
		)
	)
)

------------------------------------------------------------------------
-- LAUNCH
------------------------------------------------------------------------
format "[aioli-clonelayers] macroScript registered - category \"aioli\", action \"clonelayers\"\n"
aioli_clonelayers_open()
