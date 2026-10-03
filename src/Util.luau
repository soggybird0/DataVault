--!strict
-- Simple small table helpers.
-- I kept these allocation-aware, as client-replication calls them a lot.

--// Variables

local READONLY_ERROR = "DataVault: client data is read-only. Change it on the server."

local RawToProxy: { [any]: any } = setmetatable({}, { __mode = "kv" }) :: any
local ProxyToRaw: { [any]: any } = setmetatable({}, { __mode = "kv" }) :: any

--// Class

local Util = {}

function Util.DeepCopy(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end

	local Copy = table.clone(Value)
	for Key, Child in Copy do
		if type(Child) == "table" then
			Copy[Key] = Util.DeepCopy(Child)
		end
	end
	return Copy
end

function Util.DeepFreeze(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end
	if table.isfrozen(Value) then
		return Value
	end

	for _, Child in Value do
		if type(Child) == "table" then
			Util.DeepFreeze(Child)
		end
	end

	return table.freeze(Value)
end

function Util.DeepEqual(A: any, B: any): boolean
	if A == B then
		return true
	end
	if type(A) ~= "table" or type(B) ~= "table" then
		return false
	end

	for Key, Value in A do
		if not Util.DeepEqual(Value, B[Key]) then
			return false
		end
	end
	for Key in B do
		if A[Key] == nil then
			return false
		end
	end
	return true
end

function Util.Unwrap(Value: any): any
	if type(Value) ~= "table" then
		return Value
	end
	local Raw = ProxyToRaw[Value]
	if Raw ~= nil then
		return Raw
	end
	return Value
end

function Util.IsReadOnly(Value: any): boolean
	return type(Value) == "table" and ProxyToRaw[Value] ~= nil
end

function Util.ReadOnly(Value: any, Message: string?): any
	if type(Value) ~= "table" then
		return Value
	end
	if ProxyToRaw[Value] ~= nil then
		return Value
	end

	local Existing = RawToProxy[Value]
	if Existing then
		return Existing
	end

	local ErrorMessage = Message or READONLY_ERROR
	local Proxy = {}

	local Meta = {
		__index = function(_, Key)
			return Util.ReadOnly(Value[Key], ErrorMessage)
		end,
		__newindex = function()
			error(ErrorMessage, 2)
		end,
		__iter = function()
			local NextFn, State, Init = pairs(Value)
			return function(IterState, Last)
				local Key: any, Child: any = NextFn(IterState, Last)
				if Key == nil then
					return nil
				end
				return Key, Util.ReadOnly(Child, ErrorMessage)
			end,
				State,
				Init
		end,
		__len = function()
			return #Value
		end,
	}

	table.freeze(Meta)
	setmetatable(Proxy, Meta)
	table.freeze(Proxy)

	RawToProxy[Value] = Proxy
	ProxyToRaw[Proxy] = Value
	return Proxy
end

function Util.Reconcile(Target: any, Template: any)
	if type(Target) ~= "table" or type(Template) ~= "table" then
		return
	end

	for Key, Value in Template do
		if type(Key) ~= "string" and type(Key) ~= "number" then
			continue
		end
		if Target[Key] == nil then
			Target[Key] = Util.DeepCopy(Value)
		elseif type(Target[Key]) == "table" and type(Value) == "table" then
			Util.Reconcile(Target[Key], Value)
		end
	end
end

function Util.Merge(Target: any, Source: any)
	if type(Target) ~= "table" or type(Source) ~= "table" then
		return
	end

	for Key, Value in Source do
		if type(Value) == "table" and type(Target[Key]) == "table" then
			Util.Merge(Target[Key], Value)
		else
			Target[Key] = if type(Value) == "table" then Util.DeepCopy(Value) else Value
		end
	end
end

function Util.ClonePath(Path: { any }): { any }
	local Copy = table.create(#Path)
	for Index = 1, #Path do
		Copy[Index] = Path[Index]
	end
	return Copy
end

function Util.NormalizePath(Path: any): { any }
	if type(Path) == "table" then
		return Path
	end
	if type(Path) == "string" then
		if Path == "" then
			return {}
		end
		return string.split(Path, ".")
	end
	error("DataVault: path must be a string or an array", 3)
end

function Util.GetAt(Root: any, Path: { any }): any
	local Current = Root
	for Index = 1, #Path do
		if type(Current) ~= "table" then
			return nil
		end
		Current = Current[Path[Index]]
	end
	return Current
end

function Util.HasAt(Root: any, Path: { any }): boolean
	local Current = Root
	for Index = 1, #Path do
		if type(Current) ~= "table" or Current[Path[Index]] == nil then
			return false
		end
		Current = Current[Path[Index]]
	end
	return true
end

function Util.SetAt(Root: any, Path: { any }, Value: any): any
	if #Path == 0 then
		return Value
	end

	if type(Root) ~= "table" then
		Root = {}
	end

	local Current = Root
	for Index = 1, #Path - 1 do
		local Key = Path[Index]
		local Next = Current[Key]
		if type(Next) ~= "table" then
			Next = {}
			Current[Key] = Next
		end
		Current = Next
	end

	Current[Path[#Path]] = Value
	return Root
end

local DEFAULT_COLLAPSE = 12

local function DiffInto(Old: any, New: any, Path: { any }, Patches: { { Path: { any }, Value: any } }, CollapseAt: number)
	if type(Old) ~= "table" or type(New) ~= "table" then
		if Old ~= New then
			table.insert(Patches, {
				Path = Util.ClonePath(Path),
				Value = Util.DeepCopy(New),
			})
		end
		return
	end

	local Mark = #Patches
	local Depth = #Path

	for Key, Value in New do
		Path[Depth + 1] = Key
		if Old[Key] == nil then
			table.insert(Patches, {
				Path = Util.ClonePath(Path),
				Value = Util.DeepCopy(Value),
			})
		elseif type(Value) == "table" and type(Old[Key]) == "table" then
			DiffInto(Old[Key], Value, Path, Patches, CollapseAt)
		elseif Old[Key] ~= Value then
			table.insert(Patches, {
				Path = Util.ClonePath(Path),
				Value = Util.DeepCopy(Value),
			})
		end
	end

	for Key in Old do
		if New[Key] == nil then
			Path[Depth + 1] = Key
			table.insert(Patches, {
				Path = Util.ClonePath(Path),
				Value = nil,
			})
		end
	end

	Path[Depth + 1] = nil

	if #Patches - Mark >= CollapseAt then
		for Index = #Patches, Mark + 1, -1 do
			table.remove(Patches, Index)
		end
		table.insert(Patches, {
			Path = Util.ClonePath(Path),
			Value = Util.DeepCopy(New),
		})
	end
end

function Util.Diff(Old: any, New: any, CollapseAt: number?): { { Path: { any }, Value: any } }
	local Patches = {}
	DiffInto(Old, New, {}, Patches, CollapseAt or DEFAULT_COLLAPSE)
	return Patches
end

function Util.PathKey(Path: { any }): string
	local Parts = table.create(#Path)
	for Index = 1, #Path do
		Parts[Index] = tostring(Path[Index])
	end
	return table.concat(Parts, "\0")
end

function Util.PathStartsWith(Path: { any }, Prefix: { any }): boolean
	if #Prefix > #Path then
		return false
	end
	for Index = 1, #Prefix do
		if Path[Index] ~= Prefix[Index] then
			return false
		end
	end
	return true
end

function Util.IsJSONAcceptable(Value: any): boolean
	local Kind = type(Value)
	if Kind == "number" or Kind == "string" or Kind == "boolean" or Kind == "buffer" then
		return true
	end
	if Kind ~= "table" then
		return false
	end
	for Key, Child in Value do
		local KeyKind = type(Key)
		if KeyKind ~= "string" and KeyKind ~= "number" then
			return false
		end
		if not Util.IsJSONAcceptable(Child) then
			return false
		end
	end
	return true
end

return Util
