/*-----------------------------------------------------------------------------
	aioli-phys2vray
	-----------------------------------------------------------------------------
	Replaces the native 3ds Max Physical Materials found on the selected
	objects with VRayMtl, and plugs every texture map back into the matching
	V-Ray slot. Built for FBX files coming from Blender (Principled BSDF ->
	FBX -> Physical Material on import), works on any Physical Material.

	Author   : /ai.oli collective
	Version  : 1.5 (in test)
	Compat.  : 3ds Max 2017+ (Physical Material) with V-Ray 5+ (metalness,
	           roughness mode, coat, sheen). Written for 3ds Max 2026 / V-Ray 7.
	Usage    : Scripting > Run Script, or drag & drop into 3ds Max. The script
	           registers itself in Customize User Interface, category
	           "aiolicollective", action "phys2vray".

	REPORT prints what each Physical Material holds and what would be done,
	without touching the scene. CONVERT does it, in a single undo.
	Both write their details to the MAXScript Listener (F11).

	Bitmaps become VRayBitmaps; the VRayBitmaps of one material share one
	VRayUVWRandomizer, each material has its own. Normal maps get their
	green channel flipped by default: V-Ray for 3ds Max reads them as
	DirectX (Y-), Blender writes OpenGL (Y+).

	The other way round (1.4): the VRayMtl of the selection become Physical
	Materials, VRayBitmaps become Bitmaps and VRayNormalMaps Normal Bumps, so
	an FBX or glTF export opens in Blender with its textures. EXPORT does it
	for the export only and leaves the scene as it was; CONVERT IN SCENE does
	it in the scene, in a single undo.
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
		local isDry = false         -- REPORT run: nothing is created in the scene
		local mData = #()           -- bitmaps in data slots, current material
		local mColor = #()          -- bitmaps in colour slots, current material
		local vbSrc = #()           -- Bitmaps already turned into a VRayBitmap, current material...
		local vbDst = #()           -- ...and their VRayBitmap
		local matRnd = undefined    -- the VRayUVWRandomizer of the current material
		local rndWarned = false
		local rndDumped = false
		local keptWarned = #()      -- maps whose inner Bitmaps are kept (warned once)
		local oldNormalBumps = #()  -- Normal Bumps replaced in the run (for the Slate clean-up)
		local vbMade = #()          -- Bitmaps that got (or, in REPORT, would get) a VRayBitmap
		local builtMaps = #()       -- VRayNormalMaps built in the run (released after a REPORT)
		local mtLogged = false       -- VRayBitmap default mapping type reported once per run
		local csLogged = false       -- VRayBitmap default transfer function reported once per run
		local rgbLogged = false      -- VRayBitmap default RGB primaries reported once per run
		-- V-Ray -> Physical (export to Blender)
		local rvMapSrc = #()        -- maps met in the VRayMtls...
		local rvMapData = #()       -- ...read as data or as colour...
		local rvMapDst = #()        -- ...and what the Physical gets for each
		local rvBuilt = #()         -- maps built in the run (Bitmaps, Normal Bumps)
		local rvMatSrc = #()        -- export: materials met on the selection...
		local rvMatDst = #()        -- ...and the material exported in their place
		local rvObjs = #()          -- export: objects given a temporary material...
		local rvObjMats = #()       -- ...and their own material, put back after the export
		local rvUsed = #()          -- VRayMtl map slots dealt with, current material
		local rvRndWarned = false
		local rvConverted = 0       -- VRayMtls converted in the run

		----------------------------------------------------------------
		-- UI
		----------------------------------------------------------------
		label lblSel "" align:#left width:280
		label lblFwd "PHYSICAL -> V-RAY   (imports from Blender)" align:#left offset:[0,4]

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
				tooltip:"Every Bitmap plugged in the converted materials becomes a VRayBitmap (same file, coordinates and output).\nThe old Bitmap is not modified: other materials using it keep it."
			checkbox chkRandomizer "VRayUVWRandomizer per material" checked:true offset:[14,0] \
				tooltip:"Each material gets its own VRayUVWRandomizer, shared by all its VRayBitmaps (mapSource).\nKeep it neutral for unwrapped (non-tiling) textures."
			checkbox chkNormalBump "Normal Bump -> VRayNormalMap" checked:true \
				tooltip:"Rebuilds a Normal Bump as a VRayNormalMap (same maps, multipliers and flips)."
			checkbox chkWrapNormal "Bump bitmap named *normal* -> normal map" checked:true \
				tooltip:"A bare bitmap in the bump slot whose file name says normal (normal, nrm, _nor, _n)\nis read as a normal map, not as a height map: wrapped in a VRayNormalMap."
			checkbox chkFlipGreen "Flip green: OpenGL normal maps (Blender)" checked:true \
				tooltip:"V-Ray for 3ds Max reads normal maps as DirectX (Y-), Blender writes OpenGL (Y+).\nUntick for DirectX normal maps (made for 3ds Max, Unreal, Substance DirectX preset)."
			checkbox chkAlphaOpacity "Transparency map -> Opacity (Blender alpha)" checked:true \
				tooltip:"A map in the Physical transparency slot is read as an alpha cutout (Blender)\nand goes to the VRayMtl opacity slot instead of refraction."
			checkbox chkLinear "Data maps in linear (gamma 1.0 / Raw)" checked:true \
				tooltip:"Roughness, metalness, normal, bump, opacity... are data, not colour.\nVRayBitmap: transfer function none, primaries Raw (off: from 3ds Max). Bitmap kept: reloaded with gamma 1.0 (gamma mode) or Raw (OCIO).\nA bitmap also used in a colour slot is treated as colour. Colour maps always get sRGB (EXR / HDR: none)."
		)

		button btnReport "REPORT" width:136 height:30 across:2 \
			tooltip:"Prints what each Physical holds and what CONVERT would do. Changes nothing."
		button btnGo "CONVERT TO V-RAY" width:136 height:30 \
			tooltip:"Replaces the Physical Materials of the selection with VRayMtl, in a single undo."

		label lblRev "V-RAY -> PHYSICAL   (exports to Blender)" align:#left offset:[0,10]
		group "Export"
		(
			checkbox chkFbx "FBX" checked:true across:2 \
				tooltip:"Writes an .fbx of the selection."
			checkbox chkGlb "glTF binary (.glb)" checked:true \
				tooltip:"Writes a .glb of the selection next to the .fbx (3ds Max 2023+ glTF exporter).\nBlender rebuilds roughness, metalness, normal and alpha from a glTF more faithfully than from an FBX."
			checkbox chkEmbed "Embed textures in the FBX" checked:true \
				tooltip:"Embed Media: the .fbx carries its textures, Blender unpacks them on import.\nThe FBX exporter's own setting is put back after the export."
			checkbox chkUnwrap "Plug the texture found inside other maps" checked:true \
				tooltip:"FBX and glTF only carry plain bitmaps: an Output, Color Correction, Triplanar... is lost on the way.\nOn: a map holding a single texture is replaced by that texture (what the map did is lost, the log says so).\nOff: the map is plugged as it is, and Blender will not see its texture."
		)
		button btnExport "EXPORT SELECTION..." width:136 height:30 across:2 \
			tooltip:"Gives the selection Physical Materials for the export only, writes the FBX / .glb,\nthen puts the VRayMtl back. The scene is left as it was, nothing goes to the undo stack."
		button btnToPhys "CONVERT IN SCENE" width:136 height:30 \
			tooltip:"Replaces the VRayMtl of the selection with Physical Materials in the scene,\nin a single undo (Ctrl+Z to go back). Export it yourself afterwards."

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

		fn markData m =
		(
			if m != undefined do
			(
				collectBitmaps m dataBitmaps #()
				collectBitmaps m mData #()
			)
		)
		fn markColor m =
		(
			if m != undefined do
			(
				collectBitmaps m colorBitmaps #()
				collectBitmaps m mColor #()
			)
		)

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
				else if depth < 32 and not (isValidNode d) do
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

		-- The VRayUVWRandomizer of the material being converted, shared by all
		-- its VRayBitmaps. One per material: two materials never share one.
		fn materialRandomizer vm =
		(
			if matRnd == undefined and not rndWarned do
			(
				try (matRnd = VRayUVWRandomizer name:(vm.name + " UVW randomizer")) catch (matRnd = undefined)
				if matRnd == undefined then
				(
					if not rndWarned do
					(
						rndWarned = true
						warn "VRayUVWRandomizer not available on this V-Ray: VRayBitmaps left without randomizer"
					)
				)
				else
				(
					logLine ("    randomizer \"" + matRnd.name + "\" created for this material")
					if not rndDumped do
					(
						-- its defaults, so the first tests tell us what they are
						rndDumped = true
						warn ("check the randomizer settings: random offset / rotation / scale misplace unwrapped (non-tiling) textures")
						local row = "     "
						for p in (getPropNames matRnd) do
						(
							local v = getP matRnd p
							if v != undefined and not (isMap v) do row += " " + (p as string) + "=" + (fmtVal v)
						)
						logLine row
					)
				)
			)
			matRnd
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

		-- Transfer function (color_space) of a VRayBitmap: 0 none, 1 inverse
		-- gamma, 2 sRGB, 3 from 3ds Max. Data maps get none (linear). Colour
		-- maps get sRGB, what 8-bit and 16-bit textures are written in (asked
		-- for by victor.oli in 1.5, instead of "from 3ds Max"), except
		-- floating-point files (EXR, HDR), already linear: none. With "Data maps
		-- in linear" off, a data map gets "from 3ds Max". Returns #(code, label).
		fn transferFor bt isData =
		(
			local ext = toLower (getFilenameType (bitmapFile bt))
			local isFloat = (findItem #(".exr", ".hdr", ".pfm") ext) > 0
			if isData and chkLinear.checked then #(0, "none")
			else if isData then #(3, "from 3ds Max")
			else if isFloat then #(0, "none, floating-point file")
			else #(2, "sRGB")
		)

		-- A VRayBitmap that reads the same file the same way as a Bitmap.
		-- Transfer function: see transferFor. RGB primaries (rgbColorSpace):
		-- 0 Default, 1 sRGB, 2 ACEScg, 3 Raw. They are left on
		-- Default for colour maps; data maps get Raw (no conversion at all), as
		-- Chaos recommends for bump, normal, displacement and roughness maps.
		fn makeVRayBitmap bt isData vm =
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
			local tf = transferFor bt isData
			if not (setP vb #color_space tf[1]) then
				warn ("\"" + bt.name + "\": transfer function not set (" + tf[2] + ")")
			else if not csLogged do
			(
				csLogged = true
				logLine ("    VRayBitmap transfer function " + (cs0 as string) + " by default; set to 0 (none) for data maps, 2 (sRGB) for colour maps: check a colour VRayBitmap shows sRGB")
			)
			if isData and chkLinear.checked do
			(
				local rgb0 = getP vb #rgbColorSpace
				if not (setP vb #rgbColorSpace 3) then
					warn ("\"" + bt.name + "\": RGB primaries not set to Raw")
				else if not rgbLogged do
				(
					rgbLogged = true
					logLine ("    VRayBitmap RGB primaries " + (rgb0 as string) + " by default; set to 3 (Raw) for data maps: check the VRayBitmap shows Raw")
				)
			)
			-- the material's randomizer
			if chkRandomizer.checked do
			(
				local r = materialRandomizer vm
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

		-- The VRayBitmap standing for a Bitmap in the current material. One per
		-- Bitmap and material: a Bitmap shared by two materials gives two
		-- VRayBitmaps, each on its own material's randomizer. The Bitmap itself is
		-- never modified. REPORT only says what would be done.
		fn vbFor bt vm =
		(
			local r = bt
			local idx = findItem vbSrc bt
			if idx > 0 then
				r = vbDst[idx]
			else
			(
				local f = filenameFromPath (bitmapFile bt)
				local inData = (findItem mData bt) > 0
				local inColor = (findItem mColor bt) > 0
				local isData = inData and not inColor
				if inData and inColor do warn ("\"" + f + "\" is used as colour and as data: treated as colour")
				local tf = transferFor bt isData
				local tag = "  (" + (if isData then "data" else "colour") + ": transfer function " + tf[2] + \
					(if isData and chkLinear.checked then ", primaries Raw" else "") + ")"
				if isDry then
					logLine ("    would become a VRayBitmap: " + f + tag)
				else
				(
					local vb = undefined
					try (vb = makeVRayBitmap bt isData vm)
					catch
					(
						warn ("\"" + f + "\" not converted to VRayBitmap: " + (getCurrentException()))
						vb = undefined
					)
					if vb != undefined do
					(
						r = vb
						bitmapsSwapped += 1
						logLine ("    VRayBitmap: " + f + tag)
					)
				)
				append vbSrc bt
				append vbDst r
				if r != bt or isDry do appendIfUnique vbMade bt
			)
			r
		)

		-- Puts VRayBitmaps in place of the Bitmaps plugged in a map we built
		-- (the new VRayMtl, a new VRayNormalMap). A map reused as it is (Output,
		-- Mix, a kept Normal Bump...) is left untouched: it may be shared, so the
		-- Bitmaps inside it stay Bitmaps, and the log says so.
		fn swapBitmapsIn parent vm =
		(
			local n = 0
			try (n = getNumSubTexmaps parent) catch (n = 0)
			for i = 1 to n do
			(
				local sm = undefined
				try (sm = getSubTexmap parent i) catch (sm = undefined)
				if sm != undefined do
				(
					if isKindOf sm BitmapTexture then
					(
						local nb = vbFor sm vm
						if nb != sm do
							try (setSubTexmap parent i nb)
							catch (warn ("\"" + sm.name + "\": VRayBitmap could not be plugged: " + (getCurrentException())))
					)
					else if (findItem nrmDst sm) > 0 then
						swapBitmapsIn sm vm
					else
					(
						local inner = #()
						collectBitmaps sm inner #()
						if inner.count > 0 and (findItem keptWarned sm) == 0 do
						(
							append keptWarned sm
							warn ("the Bitmaps inside " + ((classOf sm) as string) + " \"" + sm.name + "\" stay Bitmaps (that map is reused as it is)")
						)
					)
				)
			)
		)

		-- A map is dead when it has owners and every one of them is an old
		-- Physical of the run (gone from the scene). Anything else -- a converted
		-- VRayMtl, a material in a sample slot, a modifier, or no owner found at
		-- all (environment...) -- keeps it alive: its Slate node is not touched.
		fn isDead m olds =
		(
			local owners = #()
			ownerMaterials m owners #() 0
			local dead = owners.count > 0
			for o in owners while dead do
				if (findItem olds o) == 0 do dead = false
			dead
		)

		-- Removes from the Slate views the nodes of the maps the conversion
		-- replaced (old Bitmaps, old Normal Bumps) once nothing in use needs them,
		-- so no cut-off node is left next to the new material.
		fn cleanViews oldMaps olds =
		(
			local dead = for m in oldMaps where (isDead m olds) collect m
			local removed = 0
			if dead.count > 0 do
			(
				local nv = 0
				try (nv = sme.GetNumViews()) catch (nv = 0)
				for i = 1 to nv do
				(
					try
					(
						local v = sme.GetView i
						-- a map shown twice in a view may need more than one pass
						local pass = 0
						local inView = for m in dead where (v.GetNodeByRef m) != undefined collect m
						while inView.count > 0 and pass < 5 do
						(
							pass += 1
							v.SelectNone()
							v.SetSelectedNodes inView
							v.DeleteSelection()
							removed += inView.count
							inView = for m in dead where (v.GetNodeByRef m) != undefined collect m
						)
					)
					catch (warn ("Slate view " + (i as string) + " not cleaned: " + (getCurrentException())))
				)
			)
			if removed > 0 do logLine ("    Slate: " + (removed as string) + " node(s) of replaced maps removed from the views")
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
		-- a normal map, or the map unchanged. A map met twice in the same
		-- material gives the same VRayNormalMap; each material gets its own
		-- (the cache is reset for every material).
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
						appendIfUnique oldNormalBumps m
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
					append builtMaps r
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
		-- VRayBitmaps at the end, in swapBitmapsIn.
		fn convertMaterial pm =
		(
			usedProps = #()
			-- one material at a time: its normal maps, VRayBitmaps and randomizer
			-- are its own, never shared with another material
			nrmSrc = #()
			nrmDst = #()
			nrmKept = #()
			mData = #()
			mColor = #()
			vbSrc = #()
			vbDst = #()
			matRnd = undefined
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

			-- Bitmaps -> VRayBitmaps, inside the maps built for this material only
			if chkVRayBitmap.checked and vbClass != undefined do swapBitmapsIn vm vm

			vm
		)

		-- Data Bitmaps that stay Bitmaps in the new materials (VRayBitmap option
		-- off, or a Bitmap inside a map reused as it is, like a kept Normal Bump)
		-- are reloaded linear in place, unless something outside the run also
		-- uses them
		fn linearFallback cm dryRun olds news =
		(
			local allowed = olds + news
			local kept = #()
			-- (in REPORT nothing is swapped yet: skip the ones that would get a VRayBitmap)
			for bt in dataBitmaps where not (dryRun and (findItem vbMade bt) > 0) do
			(
				local owners = #()
				ownerMaterials bt owners #() 0
				local inNew = false
				for o in owners while not inNew do if (findItem news o) > 0 do inNew = true
				if inNew do append kept bt
			)
			if kept.count > 0 do
			(
				local how = if cm[1] then
					(if cm[2] != undefined then ("OCIO, colour space \"" + cm[2] + "\"") else "OCIO, no Raw colour space found")
				else
					"gamma 1.0"
				logLine ""
				logLine ("Data maps that stay Bitmaps, reloaded linear (" + how + ")")
			)
			for bt in kept do
			(
				local f = filenameFromPath (bitmapFile bt)
				local inColor = (findItem colorBitmaps bt) > 0
				local outside = if inColor then undefined else (usedOutsideRun bt allowed)
				if inColor then
					warn ("\"" + f + "\" is also used in a colour slot: left as it is")
				else if outside != undefined then
					warn ("\"" + f + "\" is also used by " + (userName outside) + ", not converted here: left as it is")
				else if cm[1] and cm[2] == undefined then
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

		-- The work itself, called inside an undo block for CONVERT
		fn doWork phys dryRun cm =
		(
			local olds = #()
			local news = #()
			local swapped = #()   -- the Physicals actually replaced (gone from the scene)
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
					if ok do
					(
						converted += 1
						append swapped olds[i]
					)
				)
			)
			if chkLinear.checked do linearFallback cm dryRun olds news
			-- the old Bitmaps and Normal Bumps are not modified (other materials may
			-- use them); their cut-off nodes are taken out of the Slate views
			if not dryRun do
			(
				local oldMaps = #()
				for b in dataBitmaps do appendIfUnique oldMaps b
				for b in colorBitmaps do appendIfUnique oldMaps b
				for b in oldNormalBumps do appendIfUnique oldMaps b
				cleanViews oldMaps swapped
			)
			-- REPORT built throw-away VRayMtls and VRayNormalMaps: let go of the
			-- scene's maps they point to, so they never count as users later
			if dryRun do
			(
				for t in (news + builtMaps) do
				(
					local n = 0
					try (n = getNumSubTexmaps t) catch (n = 0)
					for i = 1 to n do try (setSubTexmap t i undefined) catch ()
				)
			)
			-- viewport display, once the maps are final
			if not dryRun do
				for vm in news where (getP vm #texmap_diffuse) != undefined do try (showTextureMap vm true) catch ()
			converted
		)

		----------------------------------------------------------------
		-- V-RAY -> PHYSICAL (export to Blender)
		-- FBX and glTF exporters know the Physical Material, Bitmaps and
		-- Normal Bumps, not V-Ray's own classes. The VRayMtl is only read;
		-- what the Physical needs is built next to it, V-Ray maps are never
		-- modified.
		----------------------------------------------------------------
		fn pct v = (((v + 0.5) as integer) as string) + "%"

		-- Bitmap or VRayBitmap (VRayHDRI on older V-Ray)
		fn isImageMap m =
		(
			local r = false
			if m != undefined do
			(
				if isKindOf m BitmapTexture then
					r = true
				else
				(
					local cn = (classOf m) as string
					r = (cn == "VRayBitmap" or cn == "VRayHDRI")
				)
			)
			r
		)

		-- Every image map under a map (not the map itself, not inside an image)
		fn collectImages m acc visited =
		(
			if m != undefined and (findItem visited m) == 0 do
			(
				append visited m
				local n = 0
				try (n = getNumSubTexmaps m) catch (n = 0)
				for i = 1 to n do
				(
					local sm = undefined
					try (sm = getSubTexmap m i) catch (sm = undefined)
					if isImageMap sm then
						appendIfUnique acc sm
					else
						collectImages sm acc visited
				)
			)
		)

		-- A Bitmap reading the same file the same way as a VRayBitmap. Data maps
		-- are read in linear in Max too (Blender sets its own colour spaces on
		-- import, this is for the Max viewport and render).
		fn rvBitmap vb isData cm =
		(
			local f = getP vb #HDRIMapName
			if f == undefined do f = ""
			if f != "" and not (doesFileExist f) do
			(
				local ff = ""
				try (ff = mapPaths.getFullFilePath f) catch (ff = "")
				if ff != undefined and ff != "" do f = ff
			)
			local bt = Bitmaptexture name:vb.name
			if f == "" then
				warn ("\"" + vb.name + "\": the VRayBitmap has no file")
			else if not (setP bt #filename f) do
				warn ("\"" + vb.name + "\": file not set on the Bitmap: " + f)
			-- tiling, offset, angle, map channel, blur
			local vc = getP vb #coords
			local bc = getP bt #coords
			if vc != undefined and bc != undefined then copyProps vc bc
			else warn ("\"" + vb.name + "\": UVW coordinates not copied")
			-- output (RGB level, invert, curve)
			local vo = getP vb #output
			local bo = getP bt #output
			if vo != undefined and bo != undefined do copyProps vo bo
			-- what the mono / RGB outputs read (an alpha cutout reads the alpha)
			for p in #(#monoOutput, #rgbOutput, #alphaSource) do
			(
				local v = getP vb p
				if (isKindOf v Number) and v != 0 and not (setP bt p v) do
					warn ("\"" + vb.name + "\": " + (p as string) + " " + (v as string) + " not set on the Bitmap")
			)
			local mt = getP vb #maptype
			if (isKindOf mt Number) and mt != 4 do
				warn ("\"" + vb.name + "\": mapping type " + (mt as string) + ", not 3ds Max standard (UVW): the Bitmap reads the UVs")
			if (getP vb #mapSource) != undefined and not rvRndWarned do
			(
				rvRndWarned = true
				warn "UVW randomizers are not carried over: the Bitmaps read the plain UVs (FBX, glTF and Blender do not know them)"
			)
			local cs = getP vb #color_space
			local lin = (isData or cs == 0) and f != "" and (doesFileExist f)
			if lin do
			(
				if cm[1] and cm[2] == undefined then
					warn ("\"" + (filenameFromPath f) + "\" not read as linear (no Raw colour space in the OCIO config)")
				else
				(
					local res = linearize bt cm[2]
					if not res[1] do warn ("\"" + (filenameFromPath f) + "\" not read as linear: " + res[2])
				)
			)
			logLine ("    VRayBitmap -> Bitmap: " + (if f == "" then "(no file)" else (filenameFromPath f)) + \
				(if f != "" and not (doesFileExist f) then "  MISSING" else "") + (if lin then "  (linear)" else ""))
			append rvBuilt bt
			bt
		)

		-- What a Physical slot gets for a map found in a VRayMtl: something FBX
		-- and glTF exporters understand. A Bitmap is reused as it is; a
		-- VRayBitmap becomes a Bitmap; a VRayNormalMap becomes a Normal Bump (a
		-- Normal Bump holding VRayBitmaps is rebuilt too); a map wrapping a single
		-- texture can be replaced by that texture (option). Cached for the run.
		fn exportMap m isData cm =
		(
			local r = m
			if m != undefined and not (isKindOf m BitmapTexture) do
			(
				-- one entry per map and reading: a VRayBitmap used as colour and as
				-- data gives two Bitmaps, one read linear
				local idx = 0
				for i = 1 to rvMapSrc.count while idx == 0 do
					if rvMapSrc[i] == m and rvMapData[i] == isData do idx = i
				if idx > 0 then
					r = rvMapDst[idx]
				else
				(
					local cn = (classOf m) as string
					if cn == "VRayBitmap" or cn == "VRayHDRI" then
						r = rvBitmap m isData cm
					else if cn == "VRayNormalMap" or classOf m == Normal_Bump then
					(
						local isV = (cn == "VRayNormalMap")
						local nIn = getP m #normal_map
						local bIn = getP m #bump_map
						local nOut = exportMap nIn true cm
						local bOut = exportMap bIn true cm
						-- the green flip says how the file was written: flipped = OpenGL
						local green = if isV then ((getP m #flip_green) == true) else ((getAny m #(#flipgreen, #flip_green)) == true)
						if nIn != undefined and not green do
							warn ("normal map \"" + m.name + "\" is read without green flip, so its file is DirectX: Blender reads OpenGL, its green will be inverted there")
						local space = if isV then (getP m #normal_map_type) else (getP m #method)
						if (isKindOf space Number) and space != 0 do
							warn ("normal map \"" + m.name + "\" is not in tangent space: Blender expects tangent space")
						if isV or nOut != nIn or bOut != bIn then
						(
							local nb = Normal_Bump name:m.name
							if isV then
							(
								setP nb #map1on ((getP m #normal_map_on) != false)
								setP nb #mult_spin (getP m #normal_map_multiplier)
								setP nb #map2on ((getP m #bump_map_on) != false)
								setP nb #bump_spin (getP m #bump_map_multiplier)
								-- Normal Bump and VRayNormalMap read the same convention:
								-- the flips carry over as they are
								local fr = firstProp nb #(#flipred, #flip_red)
								local fg = firstProp nb #(#flipgreen, #flip_green)
								local sw = firstProp nb #(#swap_rg, #swap_red_green)
								if fr != undefined do setP nb fr ((getP m #flip_red) == true)
								if fg != undefined do setP nb fg green
								if sw != undefined do setP nb sw ((getP m #swap_red_and_green) == true)
								-- same numbering: 0 tangent, 1 object, 2 screen, 3 world
								if isKindOf space Number do setP nb #method space
							)
							else
								copyProps m nb
							setP nb #normal_map nOut
							setP nb #bump_map bOut
							logLine ("    " + cn + " \"" + m.name + "\" -> Normal Bump" + (if green then ", green flipped" else ""))
							append rvBuilt nb
							r = nb
						)
					)
					else
					(
						-- another map: exporters only carry plain bitmaps
						local imgs = #()
						collectImages m imgs #()
						if chkUnwrap.checked and imgs.count == 1 then
						(
							r = exportMap imgs[1] isData cm
							warn (cn + " \"" + m.name + "\" left out, the texture inside plugged directly: what the " + cn + " did is lost")
						)
						else
						(
							local nv = 0
							for i in imgs where not (isKindOf i BitmapTexture) do nv += 1
							warn (cn + " \"" + m.name + "\" plugged as it is: FBX / glTF only carry plain bitmaps, Blender will not see it" + \
								(if nv > 0 then " (the VRayBitmaps inside stay VRayBitmaps)" else ""))
						)
					)
					append rvMapSrc m
					append rvMapData isData
					append rvMapDst r
				)
			)
			r
		)

		fn vOn vm slot = ((getP vm ((slot + "_on") as name)) != false)
		fn vMult vm slot = num (getP vm ((slot + "_multiplier") as name)) 100.0

		-- Puts the export version of a VRayMtl map into a Physical slot, keeps
		-- the V-Ray on/off state, logs it. Returns true when plugged.
		fn pplug pm pslot m vm vslot isData cm warnAmount:true =
		(
			local ok = false
			appendIfUnique rvUsed (toLower vslot)
			if m != undefined do
			(
				local em = exportMap m isData cm
				if em != undefined do
				(
					if not (setP pm (pslot as name) em) then
						warn (vslot + ": no " + pslot + " slot on this Physical Material")
					else
					(
						ok = true
						local isOn = vOn vm vslot
						if not isOn do setP pm ((pslot + "_on") as name) false
						logLine ("    " + vslot + " -> " + pslot + (if isOn then "" else " [off]") + "   " + (describeMap em 1))
						local mul = vMult vm vslot
						if warnAmount and isOn and mul < 99.9 do
							warn (vslot + " amount " + (pct mul) + " not carried: the map is plugged at 100%")
					)
				)
			)
			ok
		)

		-- Builds the Physical Material equivalent of a VRayMtl. The VRayMtl is
		-- only read.
		fn toPhysical vm cm =
		(
			rvUsed = #()
			local pm = PhysicalMaterial name:vm.name
			try (pm.effectsChannel = vm.effectsChannel) catch ()
			-- Advanced mode: reflectivity and reflection colour are read
			setP pm #material_mode 1
			local useRough = (getP vm #brdf_useRoughness) == true

			-- base -------------------------------------------------------
			local dc = getP vm #diffuse
			if isKindOf dc Color do setP pm #base_color dc
			setP pm #base_weight 1.0
			if (pplug pm "base_color_map" (getP vm #texmap_diffuse) vm "texmap_diffuse" false cm warnAmount:false) and (vOn vm "texmap_diffuse") do
			(
				local dm = vMult vm "texmap_diffuse"
				if dm < 99.9 do
				(
					-- a black swatch + map amount is a weight on the map
					if isBlack dc then
					(
						setP pm #base_weight (dm / 100.0)
						setP pm #base_color white
						logLine ("    diffuse map amount " + (pct dm) + " on a black swatch -> base weight " + (fmtVal (dm / 100.0)))
					)
					else
						warn ("texmap_diffuse amount " + (pct dm) + " blends with the colour swatch: not carried, the map is plugged at 100%")
				)
			)
			setP pm #diff_roughness (num (getP vm #diffuse_roughness) undefined)
			pplug pm "diff_rough_map" (getP vm #texmap_roughness) vm "texmap_roughness" true cm

			-- reflection -------------------------------------------------
			if (getP vm #reflection_fresnel) == false do
				warn "reflection without Fresnel: the Physical always applies Fresnel, reflections get weaker facing the camera"
			local rc = getP vm #reflection
			local rMap = getP vm #texmap_reflection
			-- a map switched off leaves the swatch in charge, as in V-Ray
			local rOn = rMap != undefined and (vOn vm "texmap_reflection")
			pplug pm "refl_color_map" rMap vm "texmap_reflection" false cm
			if rOn then
			(
				setP pm #reflectivity 1.0
				setP pm #refl_color white
			)
			else if isKindOf rc Color do
			(
				-- V-Ray reflection colour = Physical reflectivity x reflection colour
				local mx = amax #(rc.r, rc.g, rc.b)
				if mx < 0.5 then
					setP pm #reflectivity 0.0
				else
				(
					setP pm #reflectivity (mx / 255.0)
					setP pm #refl_color (rc * (255.0 / mx))
				)
			)

			-- IOR: the Physical has one, for reflection and refraction ------
			local lock = (getP vm #reflection_lockIOR) != false
			local tIor = num (getP vm #refraction_ior) undefined
			local rIor = num (getP vm #reflection_ior) undefined
			local ior = if lock or rIor == undefined then tIor else rIor
			setP pm #trans_ior ior
			local iorSlot = if lock then "texmap_refractionIOR" else "texmap_reflectionIOR"
			pplug pm "trans_ior_map" (getP vm (iorSlot as name)) vm iorSlot true cm

			-- roughness --------------------------------------------------
			local g = num (getP vm #reflection_glossiness) undefined
			local gMap = getP vm #texmap_reflectionGlossiness
			if gMap == undefined or useRough then
			(
				-- a value alone is turned into a roughness: what every exporter reads
				setP pm #roughness_inv false
				setP pm #roughness (conv g useRough true)
			)
			else
			(
				setP pm #roughness_inv true
				setP pm #roughness g
				warn "glossiness map (V-Ray roughness mode off): the Physical reads it with Inv on, FBX / glTF may drop that flag: in Blender, check the map is inverted"
			)
			pplug pm "roughness_map" gMap vm "texmap_reflectionGlossiness" true cm

			-- metalness --------------------------------------------------
			setP pm #metalness (num (getP vm #reflection_metalness) 0.0)
			pplug pm "metalness_map" (getP vm #texmap_metalness) vm "texmap_metalness" true cm

			-- refraction -------------------------------------------------
			local fc = getP vm #refraction
			local fMap = getP vm #texmap_refraction
			local tr = 0.0
			local tc = white
			if isKindOf fc Color do
			(
				local mx = amax #(fc.r, fc.g, fc.b)
				tr = mx / 255.0
				if mx > 0.5 do tc = fc * (255.0 / mx)
			)
			local fOn = fMap != undefined and (vOn vm "texmap_refraction")
			if not fOn and fMap != undefined do
				pplug pm "trans_color_map" fMap vm "texmap_refraction" false cm
			if fOn or tr > 0.001 do
			(
				-- IOR unlocked: the reflection one was kept above
				if not lock and rIor != undefined and tIor != undefined and (abs (rIor - tIor)) > 0.001 do
					warn ("IOR unlocked: reflection IOR " + (fmtVal rIor) + " kept, refraction IOR " + (fmtVal tIor) + " lost (the Physical has one IOR)")
				if fOn then
				(
					setP pm #transparency 1.0
					pplug pm "trans_color_map" fMap vm "texmap_refraction" false cm
				)
				else
				(
					setP pm #transparency tr
					setP pm #trans_color tc
					logLine ("    refraction " + (fmtVal fc) + " -> transparency " + (fmtVal tr) + ", colour " + (fmtVal tc))
				)
				-- fog: the colour reached at a depth
				local fogC = getP vm #refraction_fogColor
				local fogMap = getP vm #texmap_refraction_fog
				if fogMap != undefined or ((isKindOf fogC Color) and not (isWhite fogC)) do
				(
					if fOn or not (isWhite tc) then
						warn "refraction colour and fog colour both set: the Physical has one transparency colour, the refraction one is kept"
					else
					(
						local depth = num (getP vm #refraction_fogDepth) undefined
						if depth == undefined do
						(
							local fm = num (getP vm #refraction_fogMult) 0.0
							if fm > 0.0 do depth = 1.0 / fm
						)
						if isKindOf fogC Color do setP pm #trans_color fogC
						if depth != undefined do setP pm #trans_depth depth
						logLine ("    fog colour" + (if depth != undefined then " at depth " + (fmtVal depth) else "") + " -> transparency colour and depth")
						pplug pm "trans_color_map" fogMap vm "texmap_refraction_fog" false cm
					)
				)
				-- refraction roughness: locked to the reflection when they match
				local rg = num (getP vm #refraction_glossiness) undefined
				local rgMap = getP vm #texmap_refractionGlossiness
				if rgMap == gMap and rg != undefined and g != undefined and (abs (rg - g)) < 0.001 then
				(
					setP pm #trans_roughness_lock true
					appendIfUnique rvUsed "texmap_refractionglossiness"
				)
				else
				(
					setP pm #trans_roughness_lock false
					if rgMap == undefined or useRough then
					(
						setP pm #trans_roughness_inv false
						setP pm #trans_roughness (conv rg useRough true)
					)
					else
					(
						setP pm #trans_roughness_inv true
						setP pm #trans_roughness rg
					)
					pplug pm "trans_rough_map" rgMap vm "texmap_refractionGlossiness" true cm
				)
				if (getP vm #refraction_thinWalled) == true do setP pm #thin_walled true
				warn "refraction: Blender reads an FBX transparency as alpha (see-through), not as glass: check it after the import"
			)

			-- opacity ----------------------------------------------------
			pplug pm "cutout_map" (getP vm #texmap_opacity) vm "texmap_opacity" true cm

			-- self-illumination ------------------------------------------
			local sc = getP vm #selfIllumination
			local sSlot = firstProp vm #(#texmap_self_illumination, #texmap_selfIllumination)
			local sMap = if sSlot != undefined then (getP vm sSlot) else undefined
			if sMap != undefined or ((isKindOf sc Color) and not (isBlack sc)) do
			(
				-- the ratio Chaos' V-Ray -> Physical converter uses (V2A, E. Lecchi)
				local sm = num (getP vm #selfIllumination_multiplier) 1.0
				setP pm #emission 1.0
				setP pm #emit_color (if isKindOf sc Color then sc else white)
				setP pm #emit_luminance (sm * 477.464)
				logLine ("    self-illumination x" + (fmtVal sm) + " -> emission, luminance " + (fmtVal (sm * 477.464)) + " cd/m2")
				if sSlot != undefined do pplug pm "emit_color_map" sMap vm (sSlot as string) false cm
			)

			-- coat -------------------------------------------------------
			local ca = num (getP vm #coat_amount) 0.0
			local caMap = getP vm #texmap_coat_amount
			if ca > 0.0 or caMap != undefined do
			(
				setP pm #coating ca
				local cc = getP vm #coat_color
				if isKindOf cc Color do setP pm #coat_color cc
				local cg = num (getP vm #coat_glossiness) undefined
				local cgMap = getP vm #texmap_coat_glossiness
				if cgMap == undefined or useRough then
				(
					setP pm #coat_roughness_inv false
					setP pm #coat_roughness (conv cg useRough true)
				)
				else
				(
					setP pm #coat_roughness_inv true
					setP pm #coat_roughness cg
				)
				setP pm #coat_ior (num (getP vm #coat_ior) undefined)
				pplug pm "coat_map" caMap vm "texmap_coat_amount" true cm
				pplug pm "coat_color_map" (getP vm #texmap_coat_color) vm "texmap_coat_color" false cm
				pplug pm "coat_rough_map" cgMap vm "texmap_coat_glossiness" true cm
				if (pplug pm "coat_bump_map" (getP vm #texmap_coat_bump) vm "texmap_coat_bump" true cm warnAmount:false) do
				(
					local cbp = firstProp pm #(#clearcoat_bump_map_amt, #coat_bump_map_amt)
					if cbp != undefined do setP pm cbp ((vMult vm "texmap_coat_bump") / 100.0)
				)
			)

			-- sheen ------------------------------------------------------
			local shc = getP vm #sheen_color
			local shMap = getP vm #texmap_sheen
			local shOn = shMap != undefined and (vOn vm "texmap_sheen")
			if shOn or ((isKindOf shc Color) and not (isBlack shc)) do
			(
				local w = 1.0
				local col = white
				if (isKindOf shc Color) and not shOn do
				(
					local mx = amax #(shc.r, shc.g, shc.b)
					if mx > 0.5 do
					(
						w = mx / 255.0
						col = shc * (255.0 / mx)
					)
				)
				setP pm #sheen w
				setP pm #sheen_color col
				-- the Physical sheen roughness is always a roughness
				setP pm #sheen_roughness (conv (num (getP vm #sheen_glossiness) undefined) useRough true)
				pplug pm "sheen_color_map" shMap vm "texmap_sheen" false cm
				local shrSlot = firstProp pm #(#sheen_roughness_map, #sheen_rough_map)
				local shgMap = getP vm #texmap_sheen_glossiness
				-- (no sheen roughness slot: the map is reported with the other leftovers)
				if shrSlot != undefined and (pplug pm (shrSlot as string) shgMap vm "texmap_sheen_glossiness" true cm) and not useRough do
					warn "texmap_sheen_glossiness: a glossiness map in the Physical sheen roughness slot, check it"
			)

			-- bump / normal ----------------------------------------------
			if (pplug pm "bump_map" (getP vm #texmap_bump) vm "texmap_bump" true cm warnAmount:false) do
				setP pm #bump_map_amt ((vMult vm "texmap_bump") / 100.0)

			-- displacement -----------------------------------------------
			if (pplug pm "displacement_map" (getP vm #texmap_displacement) vm "texmap_displacement" true cm warnAmount:false) do
			(
				setP pm #displacement_map_amt ((vMult vm "texmap_displacement") / 100.0)
				warn "displacement: check the amount (V-Ray and the Physical do not use the same scale)"
			)

			-- what has no Physical counterpart here ----------------------
			local an = num (getP vm #anisotropy) 0.0
			if (abs an) > 0.001 do warn ("anisotropy " + (fmtVal an) + " not converted")
			local tl = getP vm #translucency_on
			if (isKindOf tl Number) and tl != 0 do warn "translucency (sub-surface) not converted"

			-- any other map left in the VRayMtl is reported, never lost silently
			for p in (getPropNames vm) do
			(
				local ps = toLower (p as string)
				if (matchPattern ps pattern:"texmap_*") and not (matchPattern ps pattern:"*_on") and \
					not (matchPattern ps pattern:"*_multiplier") and (findItem rvUsed ps) == 0 do
				(
					local v = getP vm p
					if isMap v do warn (ps + " not transferred (no Physical counterpart handled): " + (describeMap v 0))
				)
			)
			rvConverted += 1
			pm
		)

		-- Every VRayMtl under a material (Multi/Sub-Object, blends...)
		fn collectVRay m found visited =
		(
			if m != undefined and (findItem visited m) == 0 do
			(
				append visited m
				if ((classOf m) as string) == "VRayMtl" then
					appendIfUnique found m
				else
				(
					local n = 0
					try (n = getNumSubMtls m) catch (n = 0)
					for i = 1 to n do
					(
						local sm = undefined
						try (sm = getSubMtl m i) catch (sm = undefined)
						collectVRay sm found visited
					)
				)
			)
		)

		fn scanVRay =
		(
			local found = #()
			local visited = #()
			for o in selection where o.material != undefined do collectVRay o.material found visited
			found
		)

		-- EXPORT: the material an object carries during the export. A VRayMtl
		-- becomes a Physical; a Multi/Sub-Object holding one is copied with its
		-- sub-materials converted; another container (VRay2SidedMtl,
		-- VRayBlendMtl, VRayMtlWrapper...), which FBX and glTF do not know, is
		-- replaced by its first sub-material. Nothing here enters the scene's
		-- material tree: objects get these for the export and their own back
		-- right after.
		fn physFor m cm =
		(
			local r = m
			if m != undefined do
			(
				local idx = findItem rvMatSrc m
				if idx > 0 then
					r = rvMatDst[idx]
				else
				(
					local cn = (classOf m) as string
					if cn == "VRayMtl" then
					(
						logLine ""
						logLine ("\"" + m.name + "\" -> Physical Material")
						try (r = toPhysical m cm)
						catch
						(
							warn ("conversion failed, exported as it is: " + (getCurrentException()))
							r = m
						)
					)
					else if classOf m == Multimaterial then
					(
						local n = 0
						try (n = m.numsubs) catch (n = 0)
						local subs = for i = 1 to n collect (physFor m.materialList[i] cm)
						local changed = false
						for i = 1 to n do if subs[i] != m.materialList[i] do changed = true
						if changed do
						(
							local mm = Multimaterial numsubs:n name:m.name
							for i = 1 to n do
							(
								try (mm.materialIDList[i] = m.materialIDList[i]) catch ()
								try (mm.names[i] = m.names[i]) catch ()
								try (mm.mapEnabled[i] = m.mapEnabled[i]) catch ()
								mm.materialList[i] = subs[i]
							)
							r = mm
						)
					)
					else
					(
						local n = 0
						try (n = getNumSubMtls m) catch (n = 0)
						local sub = undefined
						if n > 0 do try (sub = getSubMtl m 1) catch (sub = undefined)
						if sub != undefined then
						(
							r = physFor sub cm
							warn (cn + " \"" + m.name + "\": FBX / glTF do not know it, its first sub-material \"" + sub.name + "\" is exported in its place")
						)
						else if matchPattern cn pattern:"VRay*" do
							warn (cn + " \"" + m.name + "\": no Physical counterpart, exported as it is (Blender will not read it)")
					)
					append rvMatSrc m
					append rvMatDst r
				)
			)
			r
		)

		fn fileStamp f = (if doesFileExist f then (getFileModDate f) else "")

		fn findExporter pat =
		(
			local cls = undefined
			for c in exporterPlugin.classes while cls == undefined do
				if matchPattern (c as string) pattern:pat do cls = c
			cls
		)

		fn exportFbx f =
		(
			local before = fileStamp f
			local cls = findExporter "FBXEXP"
			-- the FBX plug-in is loaded on first use: its parameter functions exist after
			if cls != undefined do try (pluginManager.loadClass cls) catch ()
			local oldEmbed = undefined
			try (oldEmbed = FBXExporterGetParam "EmbedTextures") catch (oldEmbed = undefined)
			try (FBXExporterSetParam "EmbedTextures" chkEmbed.checked)
			catch (warn "FBX: Embed Media could not be set, the exporter's own setting is used")
			local res = false
			try
			(
				if cls != undefined then res = exportFile f #noPrompt selectedOnly:true using:cls
				else res = exportFile f #noPrompt selectedOnly:true
			)
			catch (warn ("FBX export failed: " + (getCurrentException())))
			if oldEmbed != undefined do try (FBXExporterSetParam "EmbedTextures" oldEmbed) catch ()
			local ok = (doesFileExist f) and (res == true or (fileStamp f) != before)
			if ok then logLine ("    written: " + f + (if chkEmbed.checked then "  (textures embedded)" else ""))
			else warn ("FBX not written: " + f)
			ok
		)

		fn exportGlb f =
		(
			local ok = false
			local cls = findExporter "*gltf*"
			if cls == undefined then
				warn "no glTF exporter in this 3ds Max (built in since 3ds Max 2023): .glb not written"
			else
			(
				local before = fileStamp f
				local res = false
				try (res = exportFile f #noPrompt selectedOnly:true using:cls)
				catch (warn ("glTF export failed: " + (getCurrentException())))
				ok = (doesFileExist f) and (res == true or (fileStamp f) != before)
				if ok then logLine ("    written: " + f + "  (" + (cls as string) + ")")
				else warn ("glTF not written: " + f)
			)
			ok
		)

		-- Where to write: one dialog, the .fbx and the .glb share the name
		fn exportPaths =
		(
			local base = "export"
			if selection.count == 1 then base = selection[1].name
			else if maxFileName != "" do base = getFilenameFile maxFileName
			for c in #(":", "*", "?", "\"", "<", ">", "|", "/", "\\") do base = substituteString base c "_"
			local dir = if maxFilePath != "" then maxFilePath else ((getDir #export) + "\\")
			local useFbx = chkFbx.checked
			local f = getSaveFileName caption:"aioli-phys2vray - export for Blender" \
				filename:(dir + base + (if useFbx then ".fbx" else ".glb")) \
				types:(if useFbx then "FBX (*.fbx)|*.fbx" else "glTF binary (*.glb)|*.glb")
			local r = undefined
			if f != undefined do
			(
				local stem = (getFilenamePath f) + (getFilenameFile f)
				r = #((if chkFbx.checked then stem + ".fbx" else undefined), (if chkGlb.checked then stem + ".glb" else undefined))
			)
			r
		)

		-- EXPORT: temporary materials on the selected objects, the files, then
		-- every object gets its own material back, whatever happened before
		fn reverseExport cm paths =
		(
			local written = #()
			local prepared = true
			try
			(
				for o in (selection as array) do
				(
					local m = undefined
					try (m = o.material) catch (m = undefined)
					if m != undefined do
					(
						local nm = physFor m cm
						if nm != m do
						(
							try
							(
								o.material = nm
								append rvObjs o
								append rvObjMats m
							)
							catch (warn ("\"" + o.name + "\": export material not assigned: " + (getCurrentException())))
						)
					)
				)
			)
			catch
			(
				prepared = false
				warn ("export not written, preparation failed: " + (getCurrentException()))
			)
			if prepared do
			(
				logLine ""
				logLine "Export"
				try
				(
					if paths[1] != undefined and (exportFbx paths[1]) do append written paths[1]
					if paths[2] != undefined and (exportGlb paths[2]) do append written paths[2]
				)
				catch (warn ("export interrupted: " + (getCurrentException())))
			)
			-- the scene as it was
			local back = 0
			for i = 1 to rvObjs.count do
			(
				try (rvObjs[i].material = rvObjMats[i]; back += 1)
				catch (warn ("\"" + rvObjs[i].name + "\": its material could not be put back: " + (getCurrentException())))
			)
			if rvObjs.count > 0 do logLine ("    " + (back as string) + " object(s) given their own material back")
			-- the throw-away materials and maps let go of the scene's maps and
			-- materials, so they never count as users later (Slate clean-up)
			for t in (rvMatDst + rvBuilt) where t != undefined and (findItem rvMatSrc t) == 0 do
			(
				local k = 0
				try (k = getNumSubTexmaps t) catch (k = 0)
				for i = 1 to k do try (setSubTexmap t i undefined) catch ()
				try (k = getNumSubMtls t) catch (k = 0)
				for i = 1 to k do try (setSubMtl t i undefined) catch ()
			)
			written
		)

		-- CONVERT IN SCENE: the VRayMtls replaced wherever they are used, like the
		-- Physical -> V-Ray way, and the V-Ray maps' cut-off nodes taken out of
		-- the Slate views
		fn reverseConvert found cm =
		(
			local olds = #()
			local news = #()
			local swapped = #()
			for vm in found do
			(
				logLine ""
				logLine ("\"" + vm.name + "\" -> Physical Material")
				local pm = undefined
				try (pm = toPhysical vm cm)
				catch
				(
					warn ("conversion failed, material skipped: " + (getCurrentException()))
					pm = undefined
				)
				if pm != undefined do
				(
					append olds vm
					append news pm
				)
			)
			for i = 1 to olds.count do
			(
				local ok = true
				try (replaceInstances olds[i] news[i])
				catch
				(
					ok = false
					warn ("\"" + olds[i].name + "\" could not be replaced: " + (getCurrentException()))
				)
				if ok do append swapped olds[i]
			)
			cleanViews (makeUniqueArray rvMapSrc) swapped
			for pm in news where (getP pm #base_color_map) != undefined do try (showTextureMap pm true) catch ()
			swapped.count
		)

		fn rvReset =
		(
			rvMapSrc = #()
			rvMapData = #()
			rvMapDst = #()
			rvBuilt = #()
			rvMatSrc = #()
			rvMatDst = #()
			rvObjs = #()
			rvObjMats = #()
			rvUsed = #()
			rvRndWarned = false
			rvConverted = 0
		)

		----------------------------------------------------------------
		-- MAIN PROCESS
		----------------------------------------------------------------
		fn refreshStatus =
		(
			local phys = scanSelection()
			local vr = scanVRay()
			lblSel.text = (selection.count as string) + " object(s) selected - " + (phys.count as string) + " Physical, " + (vr.count as string) + " VRayMtl"
			btnGo.enabled = (phys.count > 0)
			btnReport.enabled = (phys.count > 0)
			btnExport.enabled = (selection.count > 0)
			btnToPhys.enabled = (vr.count > 0)
		)

		fn runTool dryRun =
		(
			warnCount = 0
			hasVRayNormal = vrayNormalAvailable()
			vbClass = vrayBitmapClass()
			isDry = dryRun
			rndWarned = false
			rndDumped = false
			keptWarned = #()
			oldNormalBumps = #()
			vbMade = #()
			builtMaps = #()
			rgbLogged = false
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

		-- V-Ray -> Physical. doExport: for the export only, the scene is left as
		-- it was; otherwise in the scene, in a single undo.
		fn runReverse doExport =
		(
			warnCount = 0
			rvReset()
			if doExport and not (chkFbx.checked or chkGlb.checked) then
				messageBox "Tick FBX and/or glTF (.glb)." title:"aioli-phys2vray"
			else if selection.count == 0 then
				lblStatus.text = "Nothing selected."
			else
			(
				local found = scanVRay()
				local proceed = true
				local paths = undefined
				if not doExport do
				(
					if found.count == 0 do
					(
						proceed = false
						lblStatus.text = "No VRayMtl on the selection."
					)
					local others = if proceed then (countOtherUsers found) else 0
					-- a material is replaced wherever it is used: say so first
					if proceed and others > 0 do
						proceed = queryBox ((others as string) + " object(s) outside the selection use these materials too.\n" + \
							"They will get the Physical Material as well: a material is replaced wherever it is used.\n\nContinue?") \
							title:"aioli-phys2vray"
				)
				if proceed and doExport do
				(
					paths = exportPaths()
					if paths == undefined do proceed = false
				)
				if proceed do
				(
					local cm = detectColorMgmt()
					local n = 0
					local written = #()
					-- EXPORT leaves the scene as it was: it must not ask to be saved
					local dirty = true
					try (dirty = getSaveRequired()) catch (dirty = true)
					logLine ""
					logLine ("[aioli-phys2vray] " + (if doExport then "EXPORT FOR BLENDER" else "V-RAY -> PHYSICAL") + " - " + \
						(found.count as string) + " VRayMtl on " + (selection.count as string) + " selected object(s)")
					disableSceneRedraw()
					try
					(
						with animate off
						(
							if doExport then
								undo off (written = reverseExport cm paths)
							else
								undo "aioli-phys2vray V-Ray to Physical" on (n = reverseConvert found cm)
						)
					)
					catch
					(
						warn ("unexpected error: " + (getCurrentException()))
					)
					enableSceneRedraw()
					completeRedraw()
					if doExport and not dirty do try (setSaveRequired false) catch ()
					local msg = if doExport then
						((rvConverted as string) + " VRayMtl converted for the export, " + (written.count as string) + " file(s) written, " + (warnCount as string) + " warning(s).")
					else
						((n as string) + " VRayMtl replaced by Physical, " + (warnCount as string) + " warning(s). Ctrl+Z to go back.")
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
				setINISetting iniFile "Settings" "ExportFbx" (chkFbx.checked as string)
				setINISetting iniFile "Settings" "ExportGlb" (chkGlb.checked as string)
				setINISetting iniFile "Settings" "EmbedTextures" (chkEmbed.checked as string)
				setINISetting iniFile "Settings" "UnwrapMaps" (chkUnwrap.checked as string)
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
					v = getINISetting iniFile "Settings" "ExportFbx"; if v != "" do chkFbx.checked = (v == "true")
					v = getINISetting iniFile "Settings" "ExportGlb"; if v != "" do chkGlb.checked = (v == "true")
					v = getINISetting iniFile "Settings" "EmbedTextures"; if v != "" do chkEmbed.checked = (v == "true")
					v = getINISetting iniFile "Settings" "UnwrapMaps"; if v != "" do chkUnwrap.checked = (v == "true")
				)
			)
			catch()
		)

		----------------------------------------------------------------
		-- HANDLERS
		----------------------------------------------------------------
		on chkVRayBitmap changed st do chkRandomizer.enabled = st
		on chkFbx changed st do chkEmbed.enabled = st

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

		on btnExport pressed do
		(
			saveSettings()
			runReverse true
		)

		on btnToPhys pressed do
		(
			saveSettings()
			runReverse false
		)

		on aioli_roPhys2Vray open do
		(
			loadSettings()
			chkRandomizer.enabled = chkVRayBitmap.checked
			chkEmbed.enabled = chkFbx.checked
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
	src += "toolTip:\"aioli-phys2vray - Physical Material <-> VRayMtl, maps plugged back\"\n"
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
