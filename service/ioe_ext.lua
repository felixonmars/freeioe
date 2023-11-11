local lfs = require 'lfs'
local cjson = require 'cjson.safe'

local skynet = require 'skynet.manager'
local snax = require 'skynet.snax'
local queue = require 'skynet.queue'
local datacenter = require 'skynet.datacenter'

local log = require 'utils.logger'.new('EXT')
local sysinfo = require 'utils.sysinfo'
local ioe = require 'ioe'
local pkg = require 'pkg'
local pkg_api = require 'pkg.api'

local ext_lock = nil

local tasks = {}
local installed = {}
local command = {}

local get_target_folder = pkg.get_ext_folder
local get_target_root = pkg.get_ext_root
local get_ext_version = pkg.get_ext_version
local parse_version_string = pkg.parse_version_string
local get_app_target_folder = pkg.get_app_folder

local function make_inst_name(lib_name, version)
	assert(lib_name, 'The instance name is required!')
	return lib_name..'.'..(version or 'latest')
end

local function parse_inst_name(inst_name)
	if string.len(inst_name) > 8 and string.sub(inst_name, -7) == '.latest' then
		return string.sub(inst_name, 1, -8), 'latest'
	end
	return string.match(inst_name, '^(.+).(%d+)$')
end

local function action_result(id, result, ...)
	if result then
		log.info(...)
	else
		log.error(...)
	end

	if id then
		local cloud = snax.queryservice('cloud')
		cloud.post.action_result('sys', id, result, ...)
	end
	return result, ...
end

local function cloud_update_ext_list()
	local cloud = snax.queryservice('cloud')
	cloud.post.ext_list('__fake_id__from_freeioe_'..os.time(), {})
end

--[[
local function xpcall_ret(id, ok, ...)
	if ok then
		return action_result(id, ...)
	end
	return action_result(id, false, ...)
end

local function action_exec(func)
	local func = func
	return function(id, args)
		return xpcall_ret(id, xpcall(func, debug.traceback, id, args))
	end
end
]]--


local function create_task(func, task_name, ...)
	skynet.fork(function(task_name, ...)
		tasks[coroutine.running()] = {
			name = task_name
		}
		func(...)
	end, task_name, ...)
end

local function map_result_action(func_name)
	local func = command[func_name]
	assert(func)
	command[func_name] = function(id, args)
		return action_result(id, ext_lock(func, id, args))
	end
end

local function create_download(ext_name, version, success_cb, ext, token)
	local down = pkg_api.create_download_func(ext_name, version, ext or ".tar.gz", true, token, true)
	return down(success_cb)
end

local function get_app_depends_json(app_inst)
	local exts = {}
	local dir = get_app_target_folder(app_inst)
	local f = io.open(dir.."/depends.json", "r")
	if f then
		local str = f:read('a')
		local deps, err = cjson.decode(str)
		if not deps then
			log.error('depends.json format error', err)
		else
			for _, v in ipairs(deps) do
				v.version = v.version or 'latest'
				table.insert(exts, { name = v.name, version = v.version, local_path = v.local_path, download_url = v.download_url })
			end
		end
	end
	return exts
end

local function get_app_depends(app_inst)
	local exts = {}
	local dir = get_app_target_folder(app_inst)
	local f = io.open(dir.."/depends.txt", "r")
	if f then
		for line in f:lines() do
			local name, version = string.match(line, '^([^:]+):(%d+)$')
			name = name or string.match(line, '^(%w+)')
			version = version or 'latest'
			table.insert(exts, { name = name, version = version})
		end
		f:close()
	else
		return get_app_depends_json(app_inst)
	end
	return exts
end

local function install_depends_to_app_ext(ext_inst, app_inst, folder)
	local src_folder = get_target_folder(ext_inst).."/"..folder.."/"
	if lfs.attributes(src_folder, 'mode') ~= 'directory' then
		return
	end
	local target_folder = get_app_target_folder(app_inst)..folder.."/"
	lfs.mkdir(target_folder)
	for filename in lfs.dir(src_folder) do
		if filename ~= '.' and filename ~= '..' then
			local path = src_folder..filename
			local mode = lfs.attributes(path, 'mode')
			if mode == 'file' or mode == 'directory' then
				local lnpath = target_folder..filename
				os.execute("rm -f "..lnpath)
				log.debug('File link ', path, lnpath)
				os.execute("ln -s "..path.." "..lnpath)
			end
		end
	end
end

local function install_depends_to_app(ext_inst, app_inst)
	log.debug("Try to install "..ext_inst.." to "..app_inst)
	install_depends_to_app_ext(ext_inst, app_inst, 'luaclib')
	install_depends_to_app_ext(ext_inst, app_inst, 'lualib')
	install_depends_to_app_ext(ext_inst, app_inst, 'bin')
end

local function remove_depends(inst)
	log.warning('Remove extension', inst)
	installed[inst] = nil
	local target_folder = get_target_folder(inst)
	os.execute("rm -rf "..target_folder)
end

local function list_installed()
	local list = {}
	local root = get_target_root()
	lfs.mkdir(root) --- make sure folder exits
	for filename in lfs.dir(root) do
		if filename ~= '.' and filename ~= '..' then
			if lfs.attributes(root..filename, 'mode') == 'directory' then
				local name, version = parse_inst_name(filename)
				log.debug('Installed extension', name, version)
				list[filename] = {
					name = name,
					version = version
				}
				if version == 'latest' then
					list[filename].real_version = get_ext_version(filename)
				end
			end
		end
	end
	return list
end

local function list_depends()
	local app_list = datacenter.get("APPS") or {}
	local depends = {}
	for app_inst, _ in pairs(app_list) do
		local exts = get_app_depends(app_inst)
		for _, ext in ipairs(exts) do
			local inst_name = make_inst_name(ext.name, ext.version)
			local dep = depends[inst_name] or {}
			table.insert(dep, app_inst)
			depends[inst_name] = dep
		end
	end
	return depends
end

---
-- Check installed exts whether its required application exists for not
local function auto_clean_exts()
	log.debug("Auto cleanup installed extensions")
	local depends = list_depends()
	for inst, _ in pairs(installed) do
		if not depends[inst] then
			remove_depends(inst)
		end
	end
	os.execute('sync &')
end

function command.list()
	return installed
end

function command.tasks()
	return tasks
end

---
-- Application wrapper will call this method for install needed extensions and then start
-- @tparam app_inst string application instance name
-- @treturn bool, string
function command.install_depends(app_inst)
	if os.getenv('IOE_DEVELOPER_MODE') then
		return true, "Developer mode will not install extenstion from server!!!"
	end

	local exts = get_app_depends(app_inst)
	if #exts == 0 then
		return true, "There no dependency extension needed by "..app_inst
	end

	for _, ext in ipairs(exts) do
		local inst = make_inst_name(ext.name, ext.version)
		if not installed[inst] then
			create_task(function()
				return command.install_ext(nil, {
					inst = inst,
					name = ext.name,
					version = ext.version,
					local_path = ext.local_path,
					download_url = ext.download_url,
				})
			end, "Download extension "..inst)
			skynet.sleep(20) -- wait for installation started
		end
	end

	--- Make sure all depends installation is run before this.
	return ext_lock(function()
		local result = true
		local failed_depends = {}

		for _, ext in pairs(exts) do
			local inst = make_inst_name(ext.name, ext.version)
			if not installed[inst] then
				result = false
				failed_depends[#failed_depends + 1] = inst
			else
				install_depends_to_app(inst, app_inst)
			end
		end

		if not result then
			return false, "Install depends failed, failed exts: "..table.concat(failed_depends)
		end
		return true, "Install depends for application is done!"
	end)
end

function command.install_ext(id, args)
	local name = args.name
	local version = args.version or 'latest'
	local inst = make_inst_name(name, version)
	if installed[inst] then
		return true, "Extension "..inst.." already installed"
	end
	if args.local_path then
		local mode = lfs.attributes(args.local_path, 'mode')
		if mode then
			log.notice("Install extension from local", name, version, args.local_path)
			local target_folder = get_target_folder(inst)
			print(target_folder)
			os.execute('ln -s '..args.local_path..' '..target_folder)
			installed[inst] = {
				name = name,
				version = version,
			}
			--- Trigger extension list upgrade
			cloud_update_ext_list()
		end
		-- download will not be needed
		return true, 'Extension installed from local'
	end

	return create_download(name, version, function(path)
		log.notice("Download extension finished", name, version)

		local target_folder = get_target_folder(inst)
		lfs.mkdir(target_folder)
		log.debug("tar xzf "..path.." -C "..target_folder)
		local r, status = os.execute("tar xzf "..path.." -C "..target_folder.."/")
		os.execute("rm -rf "..path)
		if r and status == 'exit' then
			log.notice("Install extension finished", name, version, r, status)
			installed[inst] = {
				name = name,
				version = version,
			}
			--- Trigger extension list upgrade
			cloud_update_ext_list()
			return true, "Extension "..name.." installation is done!"
		else
			log.error("Install extention failed", name, version, r, status)
			os.execute("rm -rf "..target_folder)
			return false, "failed to unzip Extension"
		end
	end)
end

function command.upgrade_ext(id, args)
	local inst = args.inst or args.name..".latest"
	if not installed[inst] then
		local err = "Extension does not exists! inst: "..inst
		return false, err
	end

	local name = args.name
	local version, beta, _ = parse_version_string(args.version)

	--- Stop all applications depends on this extension
	local depends = list_depends()
	local applist = depends[inst]
	local appmgr = snax.queryservice("appmgr")
	for _,app_inst in ipairs(applist) do
		appmgr.req.stop(app_inst, "Upgrade Extension "..inst)
	end

	return create_download(name, version, function(path)
		log.notice("Download extension finished", name, version, beta)

		local target_folder = get_target_folder(inst)
		log.debug("tar xzf "..path.." -C "..target_folder.."/")
		local r, status = os.execute("tar xzf "..path.." -C "..target_folder)
		os.execute("rm -rf "..path)
		if not r or status ~= 'exit' then
			log.error("Install extention failed", name, version, r, status)
			return false, "Extention upgradation failed to install"
		end

		log.notice("Install extension finished", name, version, r, status)
		installed[inst] = {
			name = name,
			version = version
		}

		for _,app_inst in ipairs(applist) do
			log.notice("Launch appliation", app_inst)
			appmgr.post.app_start(app_inst)
		end
		return true, "Extension upgradation is done!"
	end)
end

function command.check_version(ext, version)
	assert(ext, "Extention name required!")
	local r, err = pkg_api.check_version(ext, version, true)
	if not r then
		log.error(err)
		r = { version = 0, beta = true }
	end
	return r
end

function command.latest_version(ext)
	assert(ext, "Extention name required!")
	local r, err = pkg_api.latest_version(ext, true)
	if not r then
		log.error(err)
		r = true
	end
	return r
end

function command.auto_clean()
	auto_clean_exts()
	return true, "Extension auto clean is done!"
end

map_result_action('upgrade_ext')
map_result_action('install_ext')
map_result_action('auto_clean')

skynet.start(function()
	ext_lock = queue()
	skynet.dispatch("lua", function(session, address, cmd, ...)
		local f = command[string.lower(cmd)]
		if f then
			skynet.ret(skynet.pack(f(...)))
		else
			error(string.format("Unknown command %s from session %s-%s", tostring(cmd), tostring(session), tostring(address)))
		end
	end)
	installed = list_installed()

	skynet.fork(function()
		while true do
			skynet.sleep(10 * 60 * 100) -- 10 mins
			auto_clean_exts()
		end
	end)

	skynet.register ".ioe_ext"
end)

