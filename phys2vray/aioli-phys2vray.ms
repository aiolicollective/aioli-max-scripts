/*-----------------------------------------------------------------------------
	aioli-phys2vray
	-----------------------------------------------------------------------------
	Replaces the native 3ds Max Physical Materials found on the selected
	objects with VRayMtl, and plugs every texture map back into the matching
	V-Ray slot. Built for FBX files coming from Blender (Principled BSDF ->
	FBX -> Physical Material on import), works on any Physical Material.

	Author   : /ai.oli collective
	Version  : 1.2 (in test)
	Compat.  : 3ds Max 2017+ (Physical Material) with V-Ray 5+ (metalness,
	           roughness mode, coat, sheen). Written for 3ds Max 2026 / V-Ray 7.
	Usage    : Scripting > Run Script, or drag & drop into 3ds Max. The script
	           registers itself in Customize User Interface, category
	           "aiolicollective", action "phys2vray".

	REPORT prints what each Physical Material holds and what would be done,
	without touching the scene. CONVERT does it, in a single undo.
	Both write their details to the MAXScript Listener (F11).

	Bitmaps become VRayBitmaps, all sharing one VRayUVWRandomizer. Normal
	maps get their green channel flipped by default: V-Ray for 3ds Max reads
	them as DirectX (Y-), Blender writes OpenGL (Y+).
-----------------------------------------------------------------------------*/

global aioli_roPhys2Vray      -- the tool window
global aioli_phys2vray_open   -- entry point called by the macroScript

(
	------------------------------------------------------------------------
	-- CONSTANTS
	------------------------------------------------------------------------
	local iniFile = (getDir #plugcfg) + "\\aioli-phys2vray.ini"

	------------------------------------------------------------------------
	-- ROLLOUT
	-- (declared global at the top of the file: scene callbacks are evaluated
	--  in global scope and must be able to find the window by its name)
	------------------------------------------------------------------------
	rollout aioli_roPhys2Vray "aioli-phys2vray" width:300
	(
		----------------------------------------------------------------
		-- STATE OF ONE RUN
		----------------------------------------------------------------
		local warnCount = 0
		local nrmSrc = #()        -- maps already turned into a VRayNormalMap...
		local nrmDst = #()        -- ...and the VRayNormalMap made for each
		local nrmKept = #()       -- Normal Bumps left as they are (warned once)
		local bitmapsSwapped = 0  -- VRayBitmaps made in the run
		local dataBitmaps = #()   -- bitmaps found in data slots (roughness, normal...)
		local colorBitmaps = #()  -- bitmaps found in colour slots (base colour...)
		local usedProps = #()     -- Physical map slots dealt with, current material
		local hasVRayNormal = false -- VRayNormalMap class available (checked once per run)
		local vbClass = undefined   -- VRayBitmap (V-Ray 5+) or VRayHDRI class, checked once per run
		local rnd = undefined       -- the shared VRayUVWRandomizer of the run
		local rndTried = false
		local rndName = "phys2vray UVW randomizer"
		local mtLogged = false       -- VRayBitmap default mapping type reported once per run
		local csLogged = false       -- VRayBitmap default transfer function reported once per run

		----------------------------------------------------------------
		-- UI
		----------------------------------------------------------------
		label lblSel "" align:#left width:280

		group "Reflection"
		(
			checkbox chkPbrRefl "White reflection, Fresnel from IOR (PBR)" checked:true \
				tooltip:"Recommended for Blender FBX: reflection colour white, Fresnel from the IOR.\nOff: reflection = Physical reflectivity x reflection colour, and their maps."
			dropdownlist ddlRough "Roughness map is :" items:#("As set in the Physical (Inv)", "Roughness", "Glossiness") \
				selection:1 width:270 \
				tooltip:"Physical has an Inv(ert) toggle on roughness. Leave it to the Physical, or force how the map is read."
		)

		group "Maps"
		(
			checkbox chkVRayBitmap "Bitmap -> VRayBitmap" checked:true \
				tooltip:"Every Bitmap of the converted materials becomes a VRayBitmap (same file, coordinates and output).\nA Bitmap also used by a material outside the run is left as it is."
			checkbox chkRandomizer "Shared VRayUVWRandomizer" checked:true offset:[14,0] \
				tooltip:"Plugs the same VRayUVWRandomizer into every VRayBitmap (mapSource).\nReused from one run to the next: it is named \"phys2vray UVW randomizer\".\nKeep it neutral for unwrapped (non-tiling) textures."
			checkbox chkNormalBump "Normal Bump -> VRayNormalMap" checked:true \
				tooltip:"Rebuilds a Normal Bump as a VRayNormalMap (same maps, multipliers and flips)."
			checkbox chkWrapNormal "Bump bitmap named *normal* -> normal map" checked:true \
				tooltip:"A bare bitmap in the bump slot whose file name says normal (normal, nrm, _nor, _n)\nis read as a normal map, not as a height map: wrapped in a VRayNormalMap."
			checkbox chkFlipGreen "Flip green: OpenGL normal maps (Blender)" checked:true \
				tooltip:"V-Ray for 3ds Max reads normal maps as DirectX (Y-), Blender writes OpenGL (Y+).\nUntick for DirectX normal maps (made for 3ds Max, Unreal, Substance DirectX preset)."
			checkbox chkAlphaOpacity "Transparency map -> Opacity (Blender alpha)" checked:true \
				tooltip:"A map in the Physical transparency slot is read as an alpha cutout (Blender)\nand goes to the VRayMtl opacity slot instead of refraction."
			checkbox chkLinear "Data maps in linear (gamma 1.0 / Raw)" checked:true \
				tooltip:"Roughness, metalness, normal, bump, opacity... are data, not colour.\nVRayBitmap: transfer function none. Bitmap kept: reloaded with gamma 1.0 (gamma mode) or Raw (OCIO).\nA bitmap also used in a colour slot is treated as colour."
		)

		button btnReport "REPORT" width:136 height:30 across:2 \
			tooltip:"Prints what each Physical holds and what CONVERT would do. Changes nothing."
		button btnGo "CONVERT" width:136 height:30
		label lblStatus "" align:#left width:280 height:28

		----------------------------------------------------------------
		-- SMALL HELPERS
		----------------------------------------------------------------
		fn logLine s = format "%\n" s

		fn warn s =
		(
			warnCount += 1
			format "    ! %\n" s
		)

		fn hasP obj p =
		(
			local r = false
			if obj != undefined do try (r = isProperty obj p) catch (r = false)
			r
		)

		fn getP obj p =
		(
			local v = undefined
			if hasP obj p do try (v = getProperty obj p) catch (v = undefined)
			v
		)

		-- Sets a property when the value is defined and the property exists.
		-- Returns true on success: a missing property is never an error here,
		-- the caller decides whether it deserves a warning.
		fn setP obj p v =
		(
			local ok = false
			if v != undefined and (hasP obj p) do
				try (setProperty obj p v; ok = true) catch (ok = false)
			ok
		)

		-- First property of the list that exists on obj (several V-Ray
		-- versions, several spellings), or undefined
		fn firstProp obj props =
		(
			local r = undefined
			for p in props while r == undefined do
				if hasP obj p do r = p
			r
		)

		fn getAny obj props =
		(
			local p = firstProp obj props
			if p == undefined then undefined else getP obj p
		)

		fn isMap v = (v != undefined and superClassOf v == textureMap)

		-- Number or fallback: some Physical properties may be booleans or
		-- missing depending on the version, never compare them blindly
		fn num v def = (if isKindOf v Number then v else def)

		fn isWhite c = (isKindOf c Color and c.r > 254.0 and c.g > 254.0 and c.b > 254.0)
		fn isBlack c = (isKindOf c Color and c.r < 1.0 and c.g < 1.0 and c.b < 1.0)

		-- Roughness <-> glossiness: same value when the conventions match
		fn conv v fromRough toRough =
		(
			if not (isKindOf v Number) then undefined
			else if fromRough == toRough then v
			else 1.0 - v
		)

		fn fmtVal v =
		(
			local s = ""
			if isKindOf v Float then
				s = formattedPrint v format:".3f"
			else if isKindOf v Color then
				s = "(" + ((v.r as integer) as string) + " " + ((v.g as integer) as string) + " " + ((v.b as integer) as string) + ")"
			else
				s = v as string
			s
		)

		-- Map of a Physical slot, by slot name ("base_color_map")
		fn pmap pm slot = getP pm (slot as name)

		-- false only when the Physical explicitly switched the map off
		fn mapOn pm slot = ((getP pm ((slot + "_on") as name)) != false)

		----------------------------------------------------------------
		-- BITMAPS
		----------------------------------------------------------------
		fn bitmapFile bt =
		(
			-- the file name first: bt.bitmap loads the whole image
			local f = ""
			try (f = bt.filename) catch (f = "")
			if f == undefined do f = ""
			-- relative path or path from another machine: let Max resolve it
			if f != "" and not (doesFileExist f) do
			(
				local ff = ""
				try (ff = mapPaths.getFullFilePath f) catch (ff = "")
				if ff != undefined and ff != "" do f = ff
			)
			if f == "" or not (doesFileExist f) do
			(
				local fb = ""
				try (fb = bt.bitmap.filename) catch (fb = "")
				if fb != undefined and fb != "" do f = fb
			)
			f
		)

		fn bitmapInfo bt =
		(
			local f = bitmapFile bt
			local s = "[" + (if f == "" then "no file" else (filenameFromPath f)) + "]"
			if f != "" and not (doesFileExist f) do s += " MISSING"
			local g = undefined
			try (g = bt.bitmap.gamma) catch (g = undefined)
			if g != undefined do s += " gamma:" + (fmtVal g)
			local cs = undefined
			try (cs = bt.bitmap.colorSpace) catch (cs = undefined)
			if cs != undefined do s += " colorspace:" + (cs as string)
			try (s += " mono:" + (bt.monoOutput as string) + " rgb:" + (bt.rgbOutput as string)) catch ()
			s
		)

		-- One-line description of a map, sub-maps included up to `depth`
		fn describeMap m depth =
		(
			local s = "-"
			if m != undefined do
			(
				s = ((classOf m) as string) + " \"" + m.name + "\""
				if isKindOf m BitmapTexture do s += " " + (bitmapInfo m)
				if depth > 0 do
				(
					local n = 0
					try (n = getNumSubTexmaps m) catch (n = 0)
					local subs = #()
					for i = 1 to n do
					(
						local sm = undefined
						try (sm = getSubTexmap m i) catch (sm = undefined)
						if sm != undefined do
						(
							local slotName = ""
							try (slotName = getSubTexmapSlotName m i) catch (slotName = "")
							append subs (slotName + ": " + (describeMap sm (depth - 1)))
						)
					)
					if subs.count > 0 do
					(
						s += " {"
						for i = 1 to subs.count do s += (if i > 1 then " | " else " ") + subs[i]
						s += " }"
					)
				)
			)
			s
		)

		-- Every Bitmaptexture under a map (the map itself included)
		fn collectBitmaps m acc visited =
		(
			if m != undefined and (findItem visited m) == 0 do
			(
				append visited m
				if isKindOf m BitmapTexture do appendIfUnique acc m
				local n = 0
				try (n = getNumSubTexmaps m) catch (n = 0)
				for i = 1 to n do
				(
					local sm = undefined
					try (sm = getSubTexmap m i) catch (sm = undefined)
					collectBitmaps sm acc visited
				)
			)
		)

		fn markData m = (if m != undefined do collectBitmaps m dataBitmaps #())
		fn markColor m = (if m != undefined do collectBitmaps m colorBitmaps #())

		-- Colour management of the scene: #(isOcio, rawColourSpaceName)
		-- 3ds Max 2024+ has OCIO; before that, or in gamma mode, the old
		-- gamma override applies.
		fn detectColorMgmt =
		(
			local isOcio = false
			local rawName = undefined
			try (isOcio = matchPattern ((ColorPipelineMgr.mode) as string) pattern:"*ocio*") catch (isOcio = false)
			if isOcio do
			(
				try
				(
					local lst = ColorPipelineMgr.GetFileIOColorSpaceList()
					for n in lst while rawName == undefined do
						if (toLower (n as string)) == "raw" do rawName = n as string
					for n in lst while rawName == undefined do
						if matchPattern (n as string) pattern:"*raw*" do rawName = n as string
				)
				catch (rawName = undefined)
			)
			#(isOcio, rawName)
		)

		-- Reloads a bitmap so that it is read as data: Raw colour space in
		-- OCIO mode, gamma 1.0 otherwise. Returns #(ok, note).
		-- Max may ignore the request (colorSpace: only works in OCIO mode,
		-- gamma: only in gamma mode), so what it gives back is checked
		-- whenever the bitmap tells us.
		fn linearize bt rawName =
		(
			local ok = false
			local note = ""
			local f = bitmapFile bt
			if f == "" or not (doesFileExist f) then
				note = "file missing"
			else
			(
				local before = ""
				try (before = bt.filename) catch (before = "")
				local bm = undefined
				if rawName != undefined then
					(try (bm = openBitmap f colorSpace:rawName) catch (bm = undefined))
				else
					(try (bm = openBitmap f gamma:1.0) catch (bm = undefined))
				if bm == undefined then
					note = "could not be opened"
				else
				(
					local got = undefined
					if rawName != undefined then
						(try (got = bm.colorSpace) catch (got = undefined))
					else
						(try (got = bm.gamma) catch (got = undefined))
					local matches = true
					if got != undefined do
						matches = if rawName != undefined then ((got as string) == rawName)
							else ((isKindOf got Number) and (abs (got - 1.0)) < 0.01)
					if not matches then
						note = "Max gave back " + (got as string) + ", left as it is"
					else
					(
						try (bt.bitmap = bm; ok = true) catch (ok = false; note = "could not be assigned")
						if ok and got == undefined do note = "not verifiable on this version"
						local after = ""
						try (after = bt.filename) catch (after = "")
						if ok and after != before do note += (if note == "" then "" else ", ") + "path now " + after
					)
				)
			)
			#(ok, note)
		)

		-- Materials that use a map. A map's direct dependents are usually
		-- parameter blocks or other maps, so walk up to the first material.
		-- A modifier (Displace, VRayDisplacementMod...) or a scene object (light
		-- projector...) met on the way is collected too: it is a user as well.
		fn ownerMaterials m acc visited depth =
		(
			local deps = #()
			try (deps = refs.dependents m) catch (deps = #())
			for d in deps where (findItem visited d) == 0 do
			(
				append visited d
				local sc = undefined
				try (sc = superClassOf d) catch (sc = undefined)
				if sc == material or sc == modifier or sc == light or sc == GeometryClass or \
					sc == shape or sc == helper or sc == camera then
					appendIfUnique acc d
				else if depth < 8 and not (isValidNode d) do
					ownerMaterials d acc visited (depth + 1)
			)
		)

		-- A material (or modifier, or object) in use in the scene, outside this
		-- run, that also uses the bitmap (we cannot know how: stay on the safe side)
		fn usedOutsideRun bt allowed =
		(
			local owners = #()
			ownerMaterials bt owners #() 0
			local outside = undefined
			for mt in owners while outside == undefined do
			(
				if (findItem allowed mt) == 0 do
				(
					local users = #()
					try (users = refs.dependentNodes mt) catch (users = #())
					if users.count > 0 do outside = mt
				)
			)
			outside
		)

		fn userName o =
		(
			local n = ""
			try (n = "\"" + o.name + "\"") catch (n = "")
			(n + " (" + ((classOf o) as string) + ")")
		)

		----------------------------------------------------------------
		-- VRAYBITMAP
		----------------------------------------------------------------
		-- V-Ray 5+ calls it VRayBitmap; older versions only know VRayHDRI
		fn vrayBitmapClass =
		(
			local c = undefined
			try (if superClassOf (VRayBitmap()) == textureMap do c = VRayBitmap) catch (c = undefined)
			if c == undefined do
				try (if superClassOf (VRayHDRI()) == textureMap do c = VRayHDRI) catch (c = undefined)
			c
		)

		-- The VRayUVWRandomizer shared by every VRayBitmap. One already in the
		-- scene under the same name (an earlier run) is reused, so all the
		-- converted assets answer to the same settings.
		fn sharedRandomizer =
		(
			if rnd == undefined and not rndTried do
			(
				rndTried = true
				local found = undefined
				try
				(
					for r in (getClassInstances VRayUVWRandomizer) while found == undefined do
						if r.name == rndName do found = r
				)
				catch (found = undefined)
				if found != undefined then
				(
					rnd = found
					logLine ("    shared randomizer: \"" + rndName + "\" already in the scene, reused")
				)
				else
				(
					try (rnd = VRayUVWRandomizer name:rndName) catch (rnd = undefined)
					if rnd == undefined then
						warn "VRayUVWRandomizer not available on this V-Ray: VRayBitmaps left without randomizer"
					else
					(
						logLine ("    shared randomizer: \"" + rndName + "\" created with V-Ray's default settings")
						warn ("check the randomizer settings: random offset / rotation / scale misplace unwrapped (non-tiling) textures")
						-- its defaults, so the first tests tell us what they are
						local row = "     "
						for p in (getPropNames rnd) do
						(
							local v = getP rnd p
							if v != undefined and not (isMap v) do row += " " + (p as string) + "=" + (fmtVal v)
						)
						logLine row
					)
				)
			)
			rnd
		)

		-- Copies every property two objects share; quiet on what does not fit
		fn copyProps src dst =
		(
			local n = 0
			if src != undefined and dst != undefined do
				for p in (getPropNames src) do
					if hasP dst p do
						try (setProperty dst p (getProperty src p); n += 1) catch ()
			n
		)

		-- Tiling 1, no offset, no rotation, map channel 1
		fn isDefaultCoords c =
		(
			local ok = true
			try
			(
				ok = (abs (c.U_Tiling - 1.0)) < 0.0001 and (abs (c.V_Tiling - 1.0)) < 0.0001 and \
					(abs c.U_Offset) < 0.0001 and (abs c.V_Offset) < 0.0001 and \
					(abs c.W_Angle) < 0.0001 and c.mapChannel == 1
			)
			catch (ok = true)
			ok
		)

		-- A VRayBitmap that reads the same file the same way as a Bitmap.
		-- Transfer function (color_space): 0 none, 1 inverse gamma, 2 sRGB,
		-- 3 from 3ds Max. Data maps get none (linear); colour maps get "from
		-- 3ds Max", so Max's colour management decides per file (8-bit sRGB,
		-- EXR linear) as it did for the Bitmap. RGB primaries are left on
		-- Default, which converts nothing.
		fn makeVRayBitmap bt isData =
		(
			local vb = vbClass name:bt.name
			local f = ""
			try (f = bt.filename) catch (f = "")
			if f == undefined or f == "" do f = bitmapFile bt
			if not (setP vb #HDRIMapName f) do warn ("\"" + bt.name + "\": file not set on the VRayBitmap")
			-- 3ds Max standard (UVW) mapping, not an environment projection
			-- (0 angular, 1 cubic, 2 spherical, 3 mirrored ball, 4 3ds Max standard)
			local mt0 = getP vb #maptype
			if mt0 != 4 and (setP vb #maptype 4) and not mtLogged do
			(
				mtLogged = true
				logLine ("    VRayBitmap mapping type " + (mt0 as string) + " by default, set to 4 (3ds Max standard)")
			)
			-- tiling, offset, angle, map channel, blur
			local bc = getP bt #coords
			local vc = getP vb #coords
			if bc != undefined and vc != undefined then copyProps bc vc
			else warn ("\"" + bt.name + "\": UVW coordinates not copied")
			-- output (RGB level, invert, curve)
			local bo = getP bt #output
			local vo = getP vb #output
			if bo != undefined and vo != undefined then copyProps bo vo
			else if bo != undefined do
			(
				local plain = true
				try (plain = (not bo.invert) and (abs (bo.RGB_Level - 1.0)) < 0.0001 and (abs (bo.output_amount - 1.0)) < 0.0001) catch (plain = true)
				if not plain do warn ("\"" + bt.name + "\": its output settings (invert, level) are not on the VRayBitmap")
			)
			-- what the mono / RGB outputs read (an alpha cutout reads the alpha)
			for p in #(#monoOutput, #rgbOutput, #alphaSource) do
			(
				local v = getP bt p
				if (isKindOf v Number) and v != 0 and not (setP vb p v) do
					warn ("\"" + bt.name + "\": " + (p as string) + " " + (v as string) + " not set on the VRayBitmap")
			)
			if (getP bt #apply) == true do warn ("\"" + bt.name + "\": crop / place not transferred")
			local cs0 = getP vb #color_space
			local csWanted = if isData and chkLinear.checked then 0 else 3
			if not (setP vb #color_space csWanted) then
				warn ("\"" + bt.name + "\": transfer function not set (" + (if csWanted == 0 then "none" else "from 3ds Max") + ")")
			else if not csLogged do
			(
				csLogged = true
				logLine ("    VRayBitmap transfer function " + (cs0 as string) + " by default; set to 0 (none) for data maps, 3 (from 3ds Max) for colour maps")
			)
			-- the shared randomizer
			if chkRandomizer.checked do
			(
				local r = sharedRandomizer()
				if r != undefined do
				(
					if not (setP vb #mapSource r) then
						warn ("\"" + bt.name + "\": randomizer not plugged (no mapSource on this VRayBitmap)")
					else if bc != undefined and not (isDefaultCoords bc) do
						warn ("\"" + bt.name + "\": tiling / offset / angle / channel not default, and the randomizer now drives its UVWs: check it")
				)
			)
			vb
		)

		----------------------------------------------------------------
		-- NORMAL MAPS
		----------------------------------------------------------------
		fn vrayNormalAvailable =
		(
			local ok = false
			try (ok = (superClassOf (VRayNormalMap()) == textureMap)) catch (ok = false)
			ok
		)

		fn looksLikeNormal f =
		(
			local n = toLower (getFilenameFile f)
			local pats = #("*normal*", "*nrm*", "*_nor", "*_nor_*", "*-nor", "*_n", "*-n")
			local hit = false
			for pt in pats while not hit do
				if matchPattern n pattern:pt do hit = true
			hit
		)

		-- Returns the map to plug in a V-Ray bump slot: a VRayNormalMap
		-- rebuilt from a Normal Bump, a bitmap wrapped when its name says it is
		-- a normal map, or the map unchanged. A map met twice gives the same
		-- VRayNormalMap, so sharing between materials is kept.
		fn toVRayNormal m =
		(
			local r = m
			local idx = findItem nrmSrc m
			if idx > 0 then
				r = nrmDst[idx]
			else if m != undefined and (findItem nrmKept m) == 0 do
			(
				if classOf m == Normal_Bump then
				(
					local meth = getP m #method
					local why = ""
					if not chkNormalBump.checked then why = "option off"
					else if not hasVRayNormal then why = "no VRayNormalMap on this V-Ray"
					else if (isKindOf meth Number) and meth != 0 do why = "not in tangent space"
					if why != "" then
					(
						-- kept as it is (a shared map is never modified in place)
						append nrmKept m
						warn ("Normal Bump \"" + m.name + "\" kept as Normal Bump (" + why + ")" + \
							(if chkFlipGreen.checked then ", green not flipped" else ""))
					)
					else
					(
						local nm = VRayNormalMap name:m.name
						setP nm #normal_map (getP m #normal_map)
						setP nm #normal_map_on ((getP m #map1on) != false)
						setP nm #normal_map_multiplier (getP m #mult_spin)
						setP nm #bump_map (getP m #bump_map)
						setP nm #bump_map_on ((getP m #map2on) != false)
						setP nm #bump_map_multiplier (getP m #bump_spin)
						-- Autodesk documents flipred / flipgreen / swap_rg, some
						-- scripts use flip_red / flip_green / swap_red_green.
						-- Normal Bump and VRayNormalMap read the same convention
						-- (DirectX): a flip already set is kept, the OpenGL option adds one.
						setP nm #flip_red ((getAny m #(#flipred, #flip_red)) == true)
						setP nm #flip_green (((getAny m #(#flipgreen, #flip_green)) == true) or chkFlipGreen.checked)
						setP nm #swap_red_and_green ((getAny m #(#swap_rg, #swap_red_green)) == true)
						logLine ("    Normal Bump \"" + m.name + "\" -> VRayNormalMap" + (if (getP nm #flip_green) == true then ", green flipped" else ""))
						r = nm
					)
				)
				else if hasVRayNormal and (isKindOf m BitmapTexture) and chkWrapNormal.checked and (looksLikeNormal (bitmapFile m)) do
				(
					local nm = VRayNormalMap name:(m.name + "_normal")
					setP nm #normal_map m
					setP nm #flip_green chkFlipGreen.checked
					logLine ("    bump bitmap \"" + (filenameFromPath (bitmapFile m)) + "\" looks like a normal map -> wrapped in a VRayNormalMap" + \
						(if chkFlipGreen.checked then ", green flipped" else ""))
					r = nm
				)
				if r != m do
				(
					append nrmSrc m
					append nrmDst r
				)
			)
			r
		)

		-- V-Ray bump multiplier (percent) for a Physical bump amount (0..1).
		-- A bitmap we wrapped ourselves was read as a height map by the
		-- Physical: its amount means nothing for a normal map, use 100.
		fn bumpMult src result amt =
		(
			if (isKindOf src BitmapTexture) and (classOf result != classOf src) then 100.0
			else (amt * 100.0)
		)

		----------------------------------------------------------------
		-- PLUGGING
		----------------------------------------------------------------
		-- Puts map m in the first VRayMtl slot of vprops that exists, keeps
		-- the Physical's on/off state, logs it. Returns true when plugged.
		fn plug vm vprops m isOn slot note:"" =
		(
			local ok = false
			if m != undefined do
			(
				appendIfUnique usedProps slot
				local p = firstProp vm vprops
				if p == undefined then
					warn (slot + ": no " + (vprops[1] as string) + " slot on this VRayMtl (V-Ray version?)")
				else if not (setP vm p m) then
					warn (slot + ": could not be plugged into " + (p as string))
				else
				(
					ok = true
					if not isOn do
						if not (setP vm (((p as string) + "_on") as name) false) do
							warn (slot + " is switched off in the Physical, could not switch it off in V-Ray")
					logLine ("    " + slot + " -> " + (p as string) + (if isOn then "" else " [off]") + \
						(if note != "" then "  (" + note + ")" else "") + "   " + (describeMap m 1))
				)
			)
			ok
		)

		-- Records a Physical map that is deliberately not transferred
		fn skipMap pm slot why =
		(
			local v = pmap pm slot
			if isMap v do
			(
				appendIfUnique usedProps slot
				warn (slot + " not transferred (" + why + "): " + (describeMap v 0))
			)
		)

		-- A V-Ray map amount blends the map with the colour swatch: with a
		-- black swatch, amount = weight gives map x weight, which is what a
		-- Physical weight does to its map.
		fn weightMap vm multProp colorProp w what =
		(
			if setP vm multProp (w * 100.0) then
			(
				setP vm colorProp black
				logLine ("    " + what + " " + (fmtVal w) + " -> map amount " + (fmtVal (w * 100.0)) + ", colour swatch black")
			)
			else
				warn (what + " " + (fmtVal w) + " not applied to the map")
		)

		----------------------------------------------------------------
		-- MATERIALS
		----------------------------------------------------------------
		fn vrayAvailable =
		(
			local ok = false
			try (ok = (superClassOf (VRayMtl()) == material)) catch (ok = false)
			ok
		)

		-- Every Physical Material under a material (Multi/Sub-Object, blends
		-- and any material that exposes sub-materials)
		fn collectPhys m found visited =
		(
			if m != undefined and (findItem visited m) == 0 do
			(
				append visited m
				if classOf m == PhysicalMaterial then
					appendIfUnique found m
				else
				(
					local n = 0
					try (n = getNumSubMtls m) catch (n = 0)
					for i = 1 to n do
					(
						local sm = undefined
						try (sm = getSubMtl m i) catch (sm = undefined)
						collectPhys sm found visited
					)
				)
			)
		)

		fn scanSelection =
		(
			local found = #()
			local visited = #()
			for o in selection where o.material != undefined do collectPhys o.material found visited
			found
		)

		-- Objects outside the selection that use these materials too
		fn countOtherUsers mats =
		(
			local selNodes = selection as array
			local others = #()
			for m in mats do
			(
				local deps = #()
				try (deps = refs.dependentNodes m) catch (deps = #())
				for n in deps where (findItem selNodes n) == 0 do appendIfUnique others n
			)
			others.count
		)

		-- REPORT: raw contents of a Physical Material
		fn dumpPhysical pm =
		(
			logLine ("Physical \"" + pm.name + "\" - contents")
			local props = #(#material_mode, #base_weight, #base_color, #diff_roughness,
				#reflectivity, #refl_color, #roughness, #roughness_inv, #metalness, #trans_ior, #brdf_mode,
				#transparency, #trans_color, #trans_depth, #trans_roughness, #trans_roughness_inv,
				#trans_roughness_lock, #thin_walled, #emission, #emit_color, #emit_luminance, #emit_kelvin,
				#coating, #sheen, #scattering, #thin_film, #anisotropy, #bump_map_amt, #displacement_map_amt)
			local row = "   "
			local cnt = 0
			for k in props do
			(
				local v = getP pm k
				if v != undefined do
				(
					row += " " + (k as string) + "=" + (fmtVal v)
					cnt += 1
					if cnt == 5 do
					(
						logLine row
						row = "   "
						cnt = 0
					)
				)
			)
			if cnt > 0 do logLine row
			for p in (getPropNames pm) do
			(
				local v = getP pm p
				if isMap v do
				(
					local st = getP pm (((p as string) + "_on") as name)
					logLine ("    " + (p as string) + (if st == false then " [off]" else "") + " = " + (describeMap v 2))
				)
			)
		)

		-- Builds the VRayMtl equivalent of a Physical Material. The Physical
		-- is only read; the maps are reused as they are (same instances), never
		-- copied, except Normal Bumps rebuilt as VRayNormalMap. Bitmaps become
		-- VRayBitmaps afterwards, in processBitmaps.
		fn convertMaterial pm =
		(
			usedProps = #()
			local vm = VRayMtl name:pm.name
			local m = undefined
			try (vm.effectsChannel = pm.effectsChannel) catch ()

			-- roughness convention ---------------------------------------
			local srcRough = ((getP pm #roughness_inv) != true)
			local useRough = srcRough
			case ddlRough.selection of
			(
				2: useRough = true
				3: useRough = false
			)
			if not (hasP vm #brdf_useRoughness) do
			(
				if useRough do warn "no roughness mode on this V-Ray: values converted to glossiness, maps plugged unchanged"
				useRough = false
			)
			setP vm #brdf_useRoughness useRough
			-- the glossiness defaults we do not overwrite keep meaning "smooth"
			if useRough do
			(
				for p in #(#refraction_glossiness, #coat_glossiness, #sheen_glossiness) do
				(
					local v = getP vm p
					if isKindOf v Number do setP vm p (1.0 - v)
				)
			)
			logLine ("    reflection read as " + (if useRough then "roughness" else "glossiness") + \
				(if useRough != srcRough then " (forced, the Physical says " + (if srcRough then "roughness" else "glossiness") + ")" else ""))

			-- base -------------------------------------------------------
			local bw = num (getP pm #base_weight) 1.0
			local bc = getP pm #base_color
			if isKindOf bc Color do setP vm #diffuse (bc * bw)
			m = pmap pm "base_color_map"
			if (plug vm #(#texmap_diffuse) m (mapOn pm "base_color_map") "base_color_map") and bw < 0.999 and (mapOn pm "base_color_map") do
				weightMap vm #texmap_diffuse_multiplier #diffuse bw "base_weight"
			markColor m
			skipMap pm "base_weight_map" "VRayMtl has no base weight map"
			setP vm #diffuse_roughness (num (getP pm #diff_roughness) undefined)
			m = pmap pm "diff_rough_map"
			plug vm #(#texmap_roughness) m (mapOn pm "diff_rough_map") "diff_rough_map"
			markData m

			-- reflection -------------------------------------------------
			local rc = getP pm #refl_color
			if not (isKindOf rc Color) do rc = white
			local rw = num (getP pm #reflectivity) 1.0
			if chkPbrRefl.checked then
			(
				setP vm #reflection white
				if rw < 0.999 or not (isWhite rc) do
					logLine ("    reflection set to white (the Physical had reflectivity " + (fmtVal rw) + ", colour " + (fmtVal rc) + ")")
				skipMap pm "refl_color_map" "PBR reflection option"
				skipMap pm "reflectivity_map" "PBR reflection option"
			)
			else
			(
				setP vm #reflection (rc * rw)
				m = pmap pm "refl_color_map"
				if m != undefined then
				(
					if (plug vm #(#texmap_reflection) m (mapOn pm "refl_color_map") "refl_color_map") and rw < 0.999 and (mapOn pm "refl_color_map") do
						weightMap vm #texmap_reflection_multiplier #reflection rw "reflectivity"
					markColor m
					skipMap pm "reflectivity_map" "refl_color_map already in the reflection slot"
				)
				else
				(
					m = pmap pm "reflectivity_map"
					plug vm #(#texmap_reflection) m (mapOn pm "reflectivity_map") "reflectivity_map" note:"weight used as reflection colour"
					markData m
				)
			)
			setP vm #reflection_fresnel true
			setP vm #reflection_lockIOR true
			local ior = num (getP pm #trans_ior) undefined
			setP vm #refraction_ior ior
			setP vm #reflection_ior ior
			m = pmap pm "trans_ior_map"
			plug vm #(#texmap_refractionIOR) m (mapOn pm "trans_ior_map") "trans_ior_map"
			markData m

			-- metalness --------------------------------------------------
			local mt = num (getP pm #metalness) 0.0
			if not (setP vm #reflection_metalness mt) and mt > 0.0 do
				warn "metalness not set: this VRayMtl has no metalness (V-Ray 5+)"
			m = pmap pm "metalness_map"
			plug vm #(#texmap_metalness) m (mapOn pm "metalness_map") "metalness_map"
			markData m

			-- roughness --------------------------------------------------
			setP vm #reflection_glossiness (conv (getP pm #roughness) srcRough useRough)
			local roughMap = pmap pm "roughness_map"
			plug vm #(#texmap_reflectionGlossiness) roughMap (mapOn pm "roughness_map") "roughness_map"
			markData roughMap

			-- opacity (cutout) -------------------------------------------
			m = pmap pm "cutout_map"
			plug vm #(#texmap_opacity) m (mapOn pm "cutout_map") "cutout_map"
			markData m

			-- transparency -----------------------------------------------
			local tr = num (getP pm #transparency) 0.0
			local tc = getP pm #trans_color
			if not (isKindOf tc Color) do tc = white
			local tMap = pmap pm "transparency_map"
			local tcMap = pmap pm "trans_color_map"
			if chkAlphaOpacity.checked and tMap != undefined then
			(
				if (getP vm #texmap_opacity) != undefined then
					skipMap pm "transparency_map" "the opacity slot already holds the cutout map"
				else
				(
					plug vm #(#texmap_opacity) tMap (mapOn pm "transparency_map") "transparency_map" note:"read as alpha"
					markData tMap
				)
				if tr > 0.001 do logLine ("    transparency weight " + (fmtVal tr) + " ignored (the map is read as alpha)")
				skipMap pm "trans_color_map" "the transparency map is read as alpha"
				skipMap pm "trans_rough_map" "the transparency map is read as alpha"
			)
			else if tr > 0.001 or tMap != undefined then
			(
				local depth = num (getP pm #trans_depth) 0.0
				if depth > 0.0 then
				(
					-- the colour is the one reached at that depth: V-Ray fog
					setP vm #refraction (white * tr)
					setP vm #refraction_fogColor tc
					if not (setP vm #refraction_fogDepth depth) do setP vm #refraction_fogMult (1.0 / depth)
					logLine ("    transparency depth " + (fmtVal depth) + " -> refraction fog (colour and depth)")
					plug vm #(#texmap_refraction_fog) tcMap (mapOn pm "trans_color_map") "trans_color_map" note:"fog colour"
					markColor tcMap
					plug vm #(#texmap_refraction) tMap (mapOn pm "transparency_map") "transparency_map" note:"weight used as refraction colour"
					markData tMap
				)
				else if tcMap != undefined then
				(
					setP vm #refraction (tc * tr)
					plug vm #(#texmap_refraction) tcMap (mapOn pm "trans_color_map") "trans_color_map"
					markColor tcMap
					if tMap != undefined then
						skipMap pm "transparency_map" "trans_color_map already in the refraction slot"
					else if tr < 0.999 and (mapOn pm "trans_color_map") do
						weightMap vm #texmap_refraction_multiplier #refraction tr "transparency"
				)
				else
				(
					setP vm #refraction (tc * tr)
					plug vm #(#texmap_refraction) tMap (mapOn pm "transparency_map") "transparency_map" note:"weight used as refraction colour"
					markData tMap
				)

				-- refraction roughness: locked to the reflection by default
				if (getP pm #trans_roughness_lock) == false then
				(
					local tSrcRough = ((getP pm #trans_roughness_inv) != true)
					setP vm #refraction_glossiness (conv (getP pm #trans_roughness) tSrcRough useRough)
					m = pmap pm "trans_rough_map"
					plug vm #(#texmap_refractionGlossiness) m (mapOn pm "trans_rough_map") "trans_rough_map"
					markData m
					if m != undefined and tSrcRough != useRough do
						warn "trans_rough_map: its roughness/glossiness convention differs from the reflection one, check it"
				)
				else
				(
					setP vm #refraction_glossiness (getP vm #reflection_glossiness)
					plug vm #(#texmap_refractionGlossiness) roughMap (mapOn pm "roughness_map") "roughness_map" note:"refraction roughness locked to reflection"
					skipMap pm "trans_rough_map" "refraction roughness locked to reflection"
				)

				if (getP pm #thin_walled) == true do
					if not (setP vm #refraction_thinWalled true) do
						warn "thin-walled not set (no such option on this VRayMtl)"
			)
			else
			(
				-- transparency weight 0 and no weight map: the Physical is opaque
				skipMap pm "trans_color_map" "the material is not transparent (weight 0)"
				skipMap pm "trans_rough_map" "the material is not transparent (weight 0)"
			)

			-- emission ---------------------------------------------------
			local em = num (getP pm #emission) 0.0
			local ec = getP pm #emit_color
			if not (isKindOf ec Color) do ec = white
			local ecMap = pmap pm "emit_color_map"
			local eMap = pmap pm "emission_map"
			if (em > 0.0 and not (isBlack ec)) or ecMap != undefined or eMap != undefined do
			(
				-- luminance (cd/m2) to V-Ray multiplier: the ratio Chaos'
				-- V-Ray -> Physical converter uses (V2A, E. Lecchi)
				local lum = num (getP pm #emit_luminance) 1500.0
				local mult = em * lum / 477.464
				setP vm #selfIllumination ec
				setP vm #selfIllumination_multiplier mult
				logLine ("    emission " + (fmtVal em) + " x " + (fmtVal lum) + " cd/m2 -> self-illumination x" + (fmtVal mult))
				if ecMap != undefined then
				(
					plug vm #(#texmap_self_illumination, #texmap_selfIllumination) ecMap (mapOn pm "emit_color_map") "emit_color_map"
					markColor ecMap
					skipMap pm "emission_map" "emit_color_map already in the self-illumination slot"
				)
				else
				(
					plug vm #(#texmap_self_illumination, #texmap_selfIllumination) eMap (mapOn pm "emission_map") "emission_map" note:"weight used as self-illumination colour"
					markData eMap
				)
				local kv = num (getP pm #emit_kelvin) 6500.0
				if (abs (kv - 6500.0)) > 1.0 do warn ("emission colour temperature " + (fmtVal kv) + " K not transferred")
			)

			-- coat -------------------------------------------------------
			local ca = num (getP pm #coating) 0.0
			local coatMaps = for s in #("coat_map", "coat_color_map", "coat_rough_map", "coat_bump_map") where (pmap pm s) != undefined collect s
			if ca > 0.0 or coatMaps.count > 0 do
			(
				if not (setP vm #coat_amount ca) then
					warn "coat not set: this VRayMtl has no coat layer (V-Ray 5+)"
				else
				(
					setP vm #coat_color (getP pm #coat_color)
					local cSrcRough = ((getP pm #coat_roughness_inv) != true)
					setP vm #coat_glossiness (conv (getP pm #coat_roughness) cSrcRough useRough)
					setP vm #coat_ior (num (getP pm #coat_ior) undefined)
					m = pmap pm "coat_map"
					plug vm #(#texmap_coat_amount) m (mapOn pm "coat_map") "coat_map"
					markData m
					m = pmap pm "coat_color_map"
					plug vm #(#texmap_coat_color) m (mapOn pm "coat_color_map") "coat_color_map"
					markColor m
					m = pmap pm "coat_rough_map"
					plug vm #(#texmap_coat_glossiness) m (mapOn pm "coat_rough_map") "coat_rough_map"
					markData m
					if m != undefined and cSrcRough != useRough do
						warn "coat_rough_map: its roughness/glossiness convention differs from the reflection one, check it"
					m = pmap pm "coat_bump_map"
					if m != undefined do
					(
						local cb = toVRayNormal m
						if (plug vm #(#texmap_coat_bump) cb (mapOn pm "coat_bump_map") "coat_bump_map") do
						(
							local camt = num (getAny pm #(#clearcoat_bump_map_amt, #coat_bump_map_amt)) 1.0
							setP vm #texmap_coat_bump_multiplier (bumpMult m cb camt)
							setP vm #coat_bump_lock false
						)
						markData m
					)
				)
			)

			-- sheen (Physical 2024+) -------------------------------------
			local sh = num (getP pm #sheen) 0.0
			local sheenMaps = for s in #("sheen_map", "sheen_color_map", "sheen_roughness_map", "sheen_rough_map") where (pmap pm s) != undefined collect s
			if sh > 0.0 or sheenMaps.count > 0 do
			(
				local sc = getP pm #sheen_color
				if not (isKindOf sc Color) do sc = white
				if not (setP vm #sheen_color (sc * sh)) then
					warn "sheen not set: this VRayMtl has no sheen layer (V-Ray 5+)"
				else
				(
					setP vm #sheen_glossiness (conv (getP pm #sheen_roughness) true useRough)
					m = pmap pm "sheen_color_map"
					if (plug vm #(#texmap_sheen) m (mapOn pm "sheen_color_map") "sheen_color_map") and sh < 0.999 and (mapOn pm "sheen_color_map") do
						weightMap vm #texmap_sheen_multiplier #sheen_color sh "sheen"
					markColor m
					skipMap pm "sheen_map" "VRayMtl has no sheen weight map"
					for s in #("sheen_roughness_map", "sheen_rough_map") do
					(
						m = pmap pm s
						if m != undefined and (getP vm #texmap_sheen_glossiness) == undefined do
						(
							plug vm #(#texmap_sheen_glossiness) m (mapOn pm s) s
							markData m
							if not useRough do warn (s + ": a roughness map plugged in glossiness mode, check it")
						)
					)
				)
			)

			-- bump / normal ----------------------------------------------
			m = pmap pm "bump_map"
			if m != undefined do
			(
				local nb = toVRayNormal m
				local amt = num (getP pm #bump_map_amt) 1.0
				if (plug vm #(#texmap_bump) nb (mapOn pm "bump_map") "bump_map") do
					setP vm #texmap_bump_multiplier (bumpMult m nb amt)
				markData m
			)

			-- displacement -----------------------------------------------
			m = pmap pm "displacement_map"
			if m != undefined do
			(
				local da = num (getP pm #displacement_map_amt) 1.0
				if (plug vm #(#texmap_displacement) m (mapOn pm "displacement_map") "displacement_map") do
				(
					setP vm #texmap_displacement_multiplier (da * 100.0)
					warn "displacement: renders only with a VRayDisplacementMod on the object, check the amount"
				)
				markData m
			)

			-- what has no V-Ray counterpart here -------------------------
			if (num (getP pm #scattering) 0.0) > 0.001 do warn "sub-surface scattering not converted"
			if (num (getP pm #thin_film) 0.0) > 0.001 do warn "thin film not converted"
			local an = num (getP pm #anisotropy) 1.0
			if (abs (an - 1.0)) > 0.001 do warn ("anisotropy " + (fmtVal an) + " not converted")

			-- any other map left in the Physical is reported, never lost silently
			for p in (getPropNames pm) do
			(
				local ps = toLower (p as string)
				if (matchPattern ps pattern:"*_map") and (findItem usedProps ps) == 0 do
				(
					local v = getP pm p
					if isMap v do warn (ps + " not transferred (no V-Ray counterpart handled): " + (describeMap v 0))
				)
			)

			vm
		)

		-- Bitmaps of the run, once every material is converted: swapped for
		-- VRayBitmaps, or (option off, or a Bitmap shared outside the run) data
		-- maps reloaded linear in place
		fn processBitmaps cm dryRun allowed =
		(
			local bmps = #()
			for b in dataBitmaps do appendIfUnique bmps b
			for b in colorBitmaps do appendIfUnique bmps b
			local useVB = chkVRayBitmap.checked and vbClass != undefined
			local how = if cm[1] then
				(if cm[2] != undefined then ("OCIO, colour space \"" + cm[2] + "\"") else "OCIO, no Raw colour space found")
			else
				"gamma 1.0"
			logLine ""
			if useVB then
				logLine ("Bitmaps -> VRayBitmap" + (if chkRandomizer.checked then ", shared randomizer" else "") + \
					(if chkLinear.checked then ", data maps linear" else ""))
			else
				logLine ("Bitmaps kept" + (if chkLinear.checked then ", data maps in linear (" + how + ")" else ""))
			if chkVRayBitmap.checked and vbClass == undefined do warn "no VRayBitmap class on this V-Ray: bitmaps kept as Bitmap"
			if bmps.count == 0 do logLine "    none"
			if useVB and dryRun and chkRandomizer.checked and bmps.count > 0 do
				logLine ("    would share one VRayUVWRandomizer, \"" + rndName + "\"")
			local swapped = 0
			for bt in bmps where useVB or (chkLinear.checked and (findItem dataBitmaps bt) > 0) do
			(
				local f = filenameFromPath (bitmapFile bt)
				local inData = (findItem dataBitmaps bt) > 0
				local inColor = (findItem colorBitmaps bt) > 0
				local isData = inData and not inColor
				if inData and inColor do warn ("\"" + f + "\" is used as colour and as data: treated as colour")
				local outside = usedOutsideRun bt allowed
				if outside != undefined then
					warn ("\"" + f + "\" is also used by " + (userName outside) + ", not converted here: left as it is")
				else if useVB then
				(
					local tag = if isData and chkLinear.checked then "  (data: transfer function none)" else ""
					if dryRun then
						logLine ("    would become a VRayBitmap: " + f + tag)
					else
					(
						local vb = undefined
						try (vb = makeVRayBitmap bt isData)
						catch
						(
							warn ("\"" + f + "\" not converted to VRayBitmap: " + (getCurrentException()))
							vb = undefined
						)
						if vb != undefined do
						(
							local ok = true
							try (replaceInstances bt vb)
							catch
							(
								ok = false
								warn ("\"" + f + "\" could not be swapped for its VRayBitmap: " + (getCurrentException()))
							)
							if ok do
							(
								swapped += 1
								logLine ("    VRayBitmap: " + f + tag)
							)
						)
					)
				)
				else if isData and chkLinear.checked do
				(
					if cm[1] and cm[2] == undefined then
						warn ("\"" + f + "\" left as it is (no Raw colour space in the OCIO config)")
					else if dryRun then
						logLine ("    would be read as data: " + f)
					else
					(
						local res = linearize bt cm[2]
						if res[1] then
							logLine ("    read as data: " + f + (if res[2] != "" then "  (" + res[2] + ")" else ""))
						else
							warn ("\"" + f + "\" not reloaded: " + res[2])
					)
				)
			)
			bitmapsSwapped = swapped
			swapped
		)

		-- The work itself, called inside an undo block for CONVERT
		fn doWork phys dryRun cm =
		(
			local olds = #()
			local news = #()
			local converted = 0
			for pm in phys do
			(
				logLine ""
				if dryRun do
					try (dumpPhysical pm) catch (warn ("could not list \"" + pm.name + "\": " + (getCurrentException())))
				logLine ((if dryRun then "Plan for \"" else "\"") + pm.name + "\" -> VRayMtl")
				local vm = undefined
				try (vm = convertMaterial pm)
				catch
				(
					warn ("conversion failed, material skipped: " + (getCurrentException()))
					vm = undefined
				)
				if vm != undefined do
				(
					append olds pm
					append news vm
				)
			)
			if not dryRun do
			(
				-- replaceInstances swaps every reference to the Physical:
				-- objects, Multi/Sub-Object slots, Material Editor slots
				for i = 1 to olds.count do
				(
					local ok = true
					try (replaceInstances olds[i] news[i])
					catch
					(
						ok = false
						warn ("\"" + olds[i].name + "\" could not be replaced: " + (getCurrentException()))
					)
					if ok do converted += 1
				)
			)
			-- Normal Bumps rebuilt as VRayNormalMap are swapped everywhere they
			-- are used (the orphaned Physicals, the Slate views), so no dead
			-- Normal Bump is left behind. Not when something outside the run
			-- still uses it. A wrapped bitmap is never swapped: its VRayNormalMap
			-- contains it.
			if not dryRun do
			(
				for i = 1 to nrmSrc.count where classOf nrmSrc[i] == Normal_Bump do
				(
					local outside = usedOutsideRun nrmSrc[i] (olds + news)
					if outside != undefined then
						logLine ("    Normal Bump \"" + nrmSrc[i].name + "\" also used by " + (userName outside) + ": kept for it")
					else
						try (replaceInstances nrmSrc[i] nrmDst[i])
						catch (warn ("Normal Bump \"" + nrmSrc[i].name + "\" could not be swapped for its VRayNormalMap: " + (getCurrentException())))
				)
			)
			-- bitmaps may be shared by the materials of this run only
			processBitmaps cm dryRun (olds + news)
			-- viewport display, once the maps are final
			if not dryRun do
				for vm in news where (getP vm #texmap_diffuse) != undefined do try (showTextureMap vm true) catch ()
			converted
		)

		----------------------------------------------------------------
		-- MAIN PROCESS
		----------------------------------------------------------------
		fn refreshStatus =
		(
			local phys = scanSelection()
			lblSel.text = (selection.count as string) + " object(s) selected - " + (phys.count as string) + " Physical material(s)"
			btnGo.enabled = (phys.count > 0)
			btnReport.enabled = (phys.count > 0)
		)

		fn runTool dryRun =
		(
			warnCount = 0
			hasVRayNormal = vrayNormalAvailable()
			vbClass = vrayBitmapClass()
			rnd = undefined
			rndTried = false
			mtLogged = false
			csLogged = false
			nrmSrc = #()
			nrmDst = #()
			nrmKept = #()
			bitmapsSwapped = 0
			dataBitmaps = #()
			colorBitmaps = #()

			if not (vrayAvailable()) then
				messageBox "V-Ray is not loaded: the VRayMtl class does not exist in this session." title:"aioli-phys2vray"
			else
			(
				local phys = scanSelection()
				local others = countOtherUsers phys
				local proceed = (phys.count > 0)

				if not proceed do lblStatus.text = "No Physical Material on the selection."

				-- A material is replaced wherever it is used: say so before
				-- touching objects that are not selected.
				if proceed and not dryRun and others > 0 do
					proceed = queryBox ((others as string) + " object(s) outside the selection use these materials too.\n" + \
						"They will get the VRayMtl as well: a material is replaced wherever it is used.\n\nContinue?") \
						title:"aioli-phys2vray"

				if proceed do
				(
					local cm = detectColorMgmt()
					local converted = 0

					logLine ""
					logLine ("[aioli-phys2vray] " + (if dryRun then "REPORT" else "CONVERT") + " - " + \
						(phys.count as string) + " Physical material(s) on " + (selection.count as string) + \
						" selected object(s), " + (others as string) + " other object(s) sharing them")

					disableSceneRedraw()
					try
					(
						with animate off
						(
							if dryRun then
								converted = doWork phys true cm
							else
								undo "aioli-phys2vray" on (converted = doWork phys false cm)
						)
					)
					catch
					(
						warn ("unexpected error: " + (getCurrentException()))
					)
					enableSceneRedraw()
					completeRedraw()

					if not dryRun do
					(
						local left = (scanSelection()).count
						if left > 0 do warn ((left as string) + " Physical material(s) still on the selection")
					)

					local msg = if dryRun then
						((phys.count as string) + " material(s) reported, " + (warnCount as string) + " warning(s).")
					else
						((converted as string) + " material(s) converted, " + (bitmapsSwapped as string) + " VRayBitmap(s), " + (warnCount as string) + " warning(s).")
					logLine ("[aioli-phys2vray] " + msg)
					lblStatus.text = msg + "\nDetails in the MAXScript Listener (F11)."
				)
			)
			refreshStatus()
		)

		----------------------------------------------------------------
		-- SETTINGS PERSISTENCE
		----------------------------------------------------------------
		fn saveSettings =
		(
			try
			(
				setINISetting iniFile "Settings" "PbrReflection" (chkPbrRefl.checked as string)
				setINISetting iniFile "Settings" "RoughMode" (ddlRough.selection as string)
				setINISetting iniFile "Settings" "NormalBump" (chkNormalBump.checked as string)
				setINISetting iniFile "Settings" "WrapNormal" (chkWrapNormal.checked as string)
				setINISetting iniFile "Settings" "FlipGreenOpenGL" (chkFlipGreen.checked as string)
				setINISetting iniFile "Settings" "VRayBitmap" (chkVRayBitmap.checked as string)
				setINISetting iniFile "Settings" "UVWRandomizer" (chkRandomizer.checked as string)
				setINISetting iniFile "Settings" "AlphaOpacity" (chkAlphaOpacity.checked as string)
				setINISetting iniFile "Settings" "Linear" (chkLinear.checked as string)
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
					v = getINISetting iniFile "Settings" "PbrReflection"; if v != "" do chkPbrRefl.checked = (v == "true")
					v = (getINISetting iniFile "Settings" "RoughMode") as integer; if v != undefined and v >= 1 and v <= 3 do ddlRough.selection = v
					v = getINISetting iniFile "Settings" "NormalBump"; if v != "" do chkNormalBump.checked = (v == "true")
					v = getINISetting iniFile "Settings" "WrapNormal"; if v != "" do chkWrapNormal.checked = (v == "true")
					-- new key in 1.1: the default went from off to on (V-Ray for 3ds Max reads
					-- normals as DirectX), an old "FlipGreen" entry must not override it
					v = getINISetting iniFile "Settings" "FlipGreenOpenGL"; if v != "" do chkFlipGreen.checked = (v == "true")
					v = getINISetting iniFile "Settings" "VRayBitmap"; if v != "" do chkVRayBitmap.checked = (v == "true")
					v = getINISetting iniFile "Settings" "UVWRandomizer"; if v != "" do chkRandomizer.checked = (v == "true")
					v = getINISetting iniFile "Settings" "AlphaOpacity"; if v != "" do chkAlphaOpacity.checked = (v == "true")
					v = getINISetting iniFile "Settings" "Linear"; if v != "" do chkLinear.checked = (v == "true")
				)
			)
			catch()
		)

		----------------------------------------------------------------
		-- HANDLERS
		----------------------------------------------------------------
		on chkVRayBitmap changed st do chkRandomizer.enabled = st

		on btnReport pressed do
		(
			saveSettings()
			runTool true
		)

		on btnGo pressed do
		(
			saveSettings()
			runTool false
		)

		on aioli_roPhys2Vray open do
		(
			loadSettings()
			chkRandomizer.enabled = chkVRayBitmap.checked
			refreshStatus()
			local cb = "try (aioli_roPhys2Vray.refreshStatus()) catch ()"
			callbacks.addScript #selectionSetChanged cb id:#aioli_phys2vray
			callbacks.addScript #sceneUndo cb id:#aioli_phys2vray
			callbacks.addScript #sceneRedo cb id:#aioli_phys2vray
		)

		on aioli_roPhys2Vray close do
		(
			saveSettings()
			callbacks.removeScripts id:#aioli_phys2vray
		)
	)

	------------------------------------------------------------------------
	-- GLOBAL ENTRY POINT
	-- Exposes opening the window so that the macroScript (toolbar button /
	-- keyboard shortcut) can call it without reloading the file.
	------------------------------------------------------------------------
	fn aioli_phys2vray_open =
	(
		try (destroyDialog aioli_roPhys2Vray) catch()
		try (callbacks.removeScripts id:#aioli_phys2vray) catch()
		createDialog aioli_roPhys2Vray
	)
)

------------------------------------------------------------------------
-- MACROSCRIPT REGISTRATION
-- Creates the "phys2vray" entry in the "aiolicollective" category of
-- Customize > Customize User Interface (Toolbars, Menus, Quads and
-- Keyboard tabs). Evaluating this block is enough: 3ds Max writes the
-- matching .mcr into its usermacros folder itself, so the entry stays
-- available on the next startups.
--
-- THE PATH TO THIS FILE IS BAKED INTO THE MACRO at drag & drop time, the
-- same way the other aiolicollective tools do it. That is what makes the
-- toolbar button work after a restart from WHEREVER the repo was cloned.
-- Unlike the first launchers, this one reads the file again at EVERY click:
-- calling the function already in memory would keep running the old version
-- after a git pull until 3ds Max is restarted (hit in test, 1.1). Move the
-- folder and you just drag the .ms in again.
------------------------------------------------------------------------
(
	local thisFile = ""
	try (thisFile = getSourceFileName()) catch()
	if thisFile == undefined do thisFile = ""

	-- Evaluated from the Listener rather than from a file: fall back to the
	-- documented install location.
	if thisFile == "" do
		thisFile = (getDir #userScripts) + "\\aioli\\phys2vray\\aioli-phys2vray.ms"

	local src = ""
	src += "macroScript aioli_phys2vray category:\"aiolicollective\" buttonText:\"phys2vray\" "
	src += "toolTip:\"aioli-phys2vray - Physical Material to VRayMtl, maps plugged back\"\n"
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
	src += "                        \"Drag aioli-phys2vray.ms into 3ds Max again.\") \\\n"
	src += "                       title:\"aioli-phys2vray\"\n"
	src += "            if aioli_phys2vray_open != undefined do aioli_phys2vray_open()\n"
	src += "        )\n"
	src += "    )\n"
	src += ")\n"
	execute src

	format "[aioli-phys2vray] macro \"phys2vray\" registered (category \"aiolicollective\")\n"
	format "[aioli-phys2vray] script : %\n" thisFile
	format "[aioli-phys2vray] button : Customize > Customize User Interface > Toolbars > Category \"aiolicollective\"\n"
)

------------------------------------------------------------------------
-- LAUNCH
------------------------------------------------------------------------
aioli_phys2vray_open()
