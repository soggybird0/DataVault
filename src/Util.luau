--!optimize 2
-- Path helpers, copies, diffs, read-only, calculated buffer codec.

local Util = {}

local PROXY_TO_RAW: { [any]: any } = setmetatable({}, { __mode = "k" })

function Util.DeepCopy(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end
	local Result = table.clone(Value)
	for K, V in Result do
		if type(V) == "table" then
			Result[K] = Util.DeepCopy(V)
		end
	end
	return Result
end

function Util.Reconcile(Target: any, Template: any)
	if type(Target) ~= "table" or type(Template) ~= "table" then
		return
	end
	for K, V in Template do
		if Target[K] == nil then
			Target[K] = Util.DeepCopy(V)
		elseif type(V) == "table" and type(Target[K]) == "table" then
			Util.Reconcile(Target[K], V)
		end
	end
end

function Util.NormalizePath(Path: any): { any }
	if type(Path) == "table" then
		local Out = table.create(#Path)
		for I, Segment in Path do
			Out[I] = Segment
		end
		return Out
	end
	if type(Path) ~= "string" or Path == "" then
		return {}
	end
	local Out = {}
	for Segment in string.gmatch(Path, "[^%.]+") do
		local AsNumber = tonumber(Segment)
		table.insert(Out, if AsNumber ~= nil and tostring(AsNumber) == Segment then AsNumber else Segment)
	end
	return Out
end

function Util.ClonePath(Path: { any }): { any }
	local Out = table.create(#Path)
	for I, Segment in Path do
		Out[I] = Segment
	end
	return Out
end

function Util.PathKey(Path: { any }): string
	local Parts = table.create(#Path)
	for I, Segment in Path do
		Parts[I] = tostring(Segment)
	end
	return table.concat(Parts, "\0")
end

function Util.PathStartsWith(Path: { any }, Prefix: { any }): boolean
	if #Prefix > #Path then
		return false
	end
	for I = 1, #Prefix do
		if Path[I] ~= Prefix[I] then
			return false
		end
	end
	return true
end

function Util.GetAt(Root: any, Path: { any }): any
	local Current = Root
	for _, Segment in Path do
		if type(Current) ~= "table" then
			return nil
		end
		Current = Current[Segment]
	end
	return Current
end

function Util.HasAt(Root: any, Path: { any }): boolean
	if #Path == 0 then
		return Root ~= nil
	end
	local Current = Root
	for I = 1, #Path - 1 do
		if type(Current) ~= "table" then
			return false
		end
		Current = Current[Path[I]]
	end
	if type(Current) ~= "table" then
		return false
	end
	return Current[Path[#Path]] ~= nil
end

function Util.SetAt(Root: any, Path: { any }, Value: any)
	if #Path == 0 then
		return
	end
	local Current = Root
	for I = 1, #Path - 1 do
		local Segment = Path[I]
		local Next = Current[Segment]
		if type(Next) ~= "table" then
			Next = {}
			Current[Segment] = Next
		end
		Current = Next
	end
	Current[Path[#Path]] = Value
end

function Util.Unwrap(Value: any): any
	return PROXY_TO_RAW[Value] or Value
end

function Util.ReadOnly(Value: any, ErrorMessage: string): any
	if type(Value) ~= "table" then
		return Value
	end
	local Proxy = newproxy(true)
	local MT = getmetatable(Proxy)
	MT.__index = function(_, Key)
		local V = Value[Key]
		if type(V) == "table" then
			return Util.ReadOnly(V, ErrorMessage)
		end
		return V
	end
	MT.__newindex = function()
		error(ErrorMessage, 2)
	end
	MT.__iter = function()
		return next, Value
	end
	MT.__len = function()
		return #Value
	end
	MT.__tostring = function()
		return "ReadOnlyData"
	end
	PROXY_TO_RAW[Proxy] = Value
	return Proxy
end

local function valuesEqual(A: any, B: any): boolean
	if A == B then
		return true
	end
	if type(A) ~= type(B) or type(A) ~= "table" then
		return false
	end
	for K, V in A do
		if not valuesEqual(V, B[K]) then
			return false
		end
	end
	for K in B do
		if A[K] == nil then
			return false
		end
	end
	return true
end

function Util.Diff(Before: any, After: any, CollapseAt: number?): { { Path: { any }, Value: any } }
	local Patches = {}
	local Limit = CollapseAt or 12

	local function walk(A: any, B: any, Path: { any })
		if valuesEqual(A, B) then
			return
		end
		if type(B) ~= "table" or type(A) ~= "table" then
			table.insert(Patches, {
				Path = Util.ClonePath(Path),
				Value = if type(B) == "table" then Util.DeepCopy(B) else B,
			})
			return
		end

		local ChildPaths = {}
		for K, BV in B do
			local AP = table.clone(Path)
			table.insert(AP, K)
			if not valuesEqual(A[K], BV) then
				table.insert(ChildPaths, { Path = AP, AV = A[K], BV = BV })
			end
		end
		for K in A do
			if B[K] == nil then
				local AP = table.clone(Path)
				table.insert(AP, K)
				table.insert(ChildPaths, { Path = AP, AV = A[K], BV = nil })
			end
		end

		if #Path > 0 and #ChildPaths >= Limit then
			table.insert(Patches, { Path = Util.ClonePath(Path), Value = Util.DeepCopy(B) })
			return
		end

		for _, Entry in ChildPaths do
			walk(Entry.AV, Entry.BV, Entry.Path)
		end
	end

	walk(Before, After, {})
	return Patches
end

-- Buffer codec ------------------------------------------------

local TYPE_NIL, TYPE_BOOL, TYPE_NUMBER, TYPE_STRING, TYPE_TABLE, TYPE_ARRAY = 0, 1, 2, 3, 4, 5

local function isArray(T: any): boolean
	if type(T) ~= "table" then
		return false
	end
	local N = #T
	if N == 0 then
		for K in T do
			if type(K) ~= "number" then
				return false
			end
		end
		return true
	end
	for K in T do
		if type(K) ~= "number" then
			return false
		end
	end
	return true
end

local function measureValue(Value: any): number
	local T = type(Value)
	if Value == nil then
		return 1
	elseif T == "boolean" then
		return 2
	elseif T == "number" then
		return 9
	elseif T == "string" then
		return 5 + #Value
	elseif T == "table" then
		if isArray(Value) then
			local Size = 5
			for I = 1, #Value do
				Size += measureValue(Value[I])
			end
			return Size
		else
			local Size = 5
			for K, V in Value do
				Size += measureValue(K) + measureValue(V)
			end
			return Size
		end
	end
	return 1
end

local function measurePath(Path: { any }): number
	local Size = 1
	for _, Segment in Path do
		Size += measureValue(Segment)
	end
	return Size
end

local function writeValue(Buf: buffer, Offset: number, Value: any): number
	local T = type(Value)
	if Value == nil then
		buffer.writeu8(Buf, Offset, TYPE_NIL)
		return Offset + 1
	elseif T == "boolean" then
		buffer.writeu8(Buf, Offset, TYPE_BOOL)
		buffer.writeu8(Buf, Offset + 1, if Value then 1 else 0)
		return Offset + 2
	elseif T == "number" then
		buffer.writeu8(Buf, Offset, TYPE_NUMBER)
		buffer.writef64(Buf, Offset + 1, Value)
		return Offset + 9
	elseif T == "string" then
		buffer.writeu8(Buf, Offset, TYPE_STRING)
		buffer.writeu32(Buf, Offset + 1, #Value)
		buffer.writestring(Buf, Offset + 5, Value)
		return Offset + 5 + #Value
	elseif T == "table" then
		if isArray(Value) then
			buffer.writeu8(Buf, Offset, TYPE_ARRAY)
			buffer.writeu32(Buf, Offset + 1, #Value)
			Offset += 5
			for I = 1, #Value do
				Offset = writeValue(Buf, Offset, Value[I])
			end
			return Offset
		else
			local Count = 0
			for _ in Value do
				Count += 1
			end
			buffer.writeu8(Buf, Offset, TYPE_TABLE)
			buffer.writeu32(Buf, Offset + 1, Count)
			Offset += 5
			for K, V in Value do
				Offset = writeValue(Buf, Offset, K)
				Offset = writeValue(Buf, Offset, V)
			end
			return Offset
		end
	end
	buffer.writeu8(Buf, Offset, TYPE_NIL)
	return Offset + 1
end

local function readValue(Buf: buffer, Offset: number): (any, number)
	local Tag = buffer.readu8(Buf, Offset)
	Offset += 1
	if Tag == TYPE_NIL then
		return nil, Offset
	elseif Tag == TYPE_BOOL then
		return buffer.readu8(Buf, Offset) == 1, Offset + 1
	elseif Tag == TYPE_NUMBER then
		return buffer.readf64(Buf, Offset), Offset + 8
	elseif Tag == TYPE_STRING then
		local Len = buffer.readu32(Buf, Offset)
		return buffer.readstring(Buf, Offset + 4, Len), Offset + 4 + Len
	elseif Tag == TYPE_ARRAY then
		local Count = buffer.readu32(Buf, Offset)
		Offset += 4
		local Arr = table.create(Count)
		for I = 1, Count do
			Arr[I], Offset = readValue(Buf, Offset)
		end
		return Arr, Offset
	elseif Tag == TYPE_TABLE then
		local Count = buffer.readu32(Buf, Offset)
		Offset += 4
		local Tbl = {}
		for _ = 1, Count do
			local K, V
			K, Offset = readValue(Buf, Offset)
			V, Offset = readValue(Buf, Offset)
			Tbl[K] = V
		end
		return Tbl, Offset
	end
	return nil, Offset
end

local function writePath(Buf: buffer, Offset: number, Path: { any }): number
	buffer.writeu8(Buf, Offset, math.min(#Path, 255))
	Offset += 1
	for I = 1, math.min(#Path, 255) do
		Offset = writeValue(Buf, Offset, Path[I])
	end
	return Offset
end

local function readPath(Buf: buffer, Offset: number): ({ any }, number)
	local Len = buffer.readu8(Buf, Offset)
	Offset += 1
	local Path = table.create(Len)
	for I = 1, Len do
		Path[I], Offset = readValue(Buf, Offset)
	end
	return Path, Offset
end

function Util.MeasureReplica(Kind: string, StoreName: string, Key: string, Seq: number, Data: any?, Patches: { any }?): number
	local Size = 1 + 4 + 2 + #StoreName + 2 + #Key
	if Kind == "Full" then
		Size += measureValue(Data)
	else
		Size += 2
		if Patches then
			for _, Patch in Patches do
				Size += measurePath(Patch.Path) + measureValue(Patch.Value)
			end
		end
	end
	return Size
end

function Util.EncodeReplica(Kind: string, StoreName: string, Key: string, Seq: number, Data: any?, Patches: { any }?): buffer
	local Size = Util.MeasureReplica(Kind, StoreName, Key, Seq, Data, Patches)
	local Buf = buffer.create(Size)
	local Offset = 0
	buffer.writeu8(Buf, Offset, if Kind == "Full" then 1 else 2)
	Offset += 1
	buffer.writeu32(Buf, Offset, Seq)
	Offset += 4
	buffer.writeu16(Buf, Offset, #StoreName)
	Offset += 2
	buffer.writestring(Buf, Offset, StoreName)
	Offset += #StoreName
	buffer.writeu16(Buf, Offset, #Key)
	Offset += 2
	buffer.writestring(Buf, Offset, Key)
	Offset += #Key
	if Kind == "Full" then
		writeValue(Buf, Offset, Data)
	else
		local Count = if Patches then #Patches else 0
		buffer.writeu16(Buf, Offset, Count)
		Offset += 2
		if Patches then
			for _, Patch in Patches do
				Offset = writePath(Buf, Offset, Patch.Path)
				Offset = writeValue(Buf, Offset, Patch.Value)
			end
		end
	end
	return Buf
end

function Util.DecodeReplica(Buf: buffer): any
	local Offset = 0
	local KindByte = buffer.readu8(Buf, Offset)
	Offset += 1
	local Seq = buffer.readu32(Buf, Offset)
	Offset += 4
	local StoreLen = buffer.readu16(Buf, Offset)
	Offset += 2
	local StoreName = buffer.readstring(Buf, Offset, StoreLen)
	Offset += StoreLen
	local KeyLen = buffer.readu16(Buf, Offset)
	Offset += 2
	local Key = buffer.readstring(Buf, Offset, KeyLen)
	Offset += KeyLen
	if KindByte == 1 then
		local Data
		Data, Offset = readValue(Buf, Offset)
		return { StoreName = StoreName, Key = Key, Seq = Seq, Kind = "Full", Data = Data }
	end
	local Count = buffer.readu16(Buf, Offset)
	Offset += 2
	local Patches = table.create(Count)
	for I = 1, Count do
		local Path, Value
		Path, Offset = readPath(Buf, Offset)
		Value, Offset = readValue(Buf, Offset)
		Patches[I] = { Path = Path, Value = Value }
	end
	return { StoreName = StoreName, Key = Key, Seq = Seq, Kind = "Patch", Patches = Patches }
end

return Util
