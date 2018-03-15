--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- lsyncd.lua   Live (Mirror) Syncing Demon
--
--
-- This is the "runner" part of Lsyncd. It containts all its high-level logic.
-- It works closely together with the Lsyncd core in lsyncd.c. This means it
-- cannot be runned directly from the standard lua interpreter.
--
--
-- This code assumes your editor is at least 100 chars wide.
--
-- License: GPLv2 (see COPYING) or any later version
-- Authors: Axel Kittenberger <axkibe@gmail.com>
--
--~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


if mantle
then
	print( 'Error, Lsyncd mantle already loaded' )
	os.exit( -1 )
end


--
-- Safes mantle stuff wrapped away from user scripts
--
local core = core
local lockGlobals = lockGlobals
local Inotify = Inotify
local Array = Array
local Queue = Queue
local Combiner = Combiner
local Delay = Delay
local InletFactory = InletFactory
local Filter = Filter


--
-- Shortcuts (which user is supposed to be able to use them as well)
--
log       = core.log
terminate = core.terminate
now       = core.now
readdir   = core.readdir


--
-- Global: total number of processess running.
--
processCount = 0


--
-- All valid entries in a settings{} call.
--
local settingsCheckgauge =
{
	logfile        = true,
	statusFile     = true,
	statusInterval = true,
	logfacility    = true,
	logident       = true,
	inotifyMode    = true,
	maxProcesses   = true,
	maxDelays      = true,
}


--
-- Settings specified by command line.
--
clSettings = { }


--
-- Settings specified by config scripts.
--
uSettings = { }



--============================================================================
-- Lsyncd Prototypes
--============================================================================


--
-- Holds information about the event monitor capabilities
-- of the core.
--
Monitors = ( function
( )
	--
	-- The cores monitor list
	--
	local list = { }


	--
	-- The default event monitor.
	--
	local function default
	( )
		return list[ 1 ]
	end


	--
	-- Initializes with info received from core
	--
	local function initialize( clist )
		for k, v in ipairs( clist )
		do
			list[ k ] = v
		end
	end


	--
	-- Public interface
	--
	return {
		default = default,
		list = list,
		initialize = initialize
	}

end)( )

--
-- Writes functions for the user for layer 3 configurations.
--
local functionWriter = ( function( )

	--
	-- All variables known to layer 3 configs.
	--
	transVars = {
		{ '%^pathname',          'event.pathname',        1 },
		{ '%^pathdir',           'event.pathdir',         1 },
		{ '%^path',              'event.path',            1 },
		{ '%^sourcePathname',    'event.sourcePathname',  1 },
		{ '%^sourcePathdir',     'event.sourcePathdir',   1 },
		{ '%^sourcePath',        'event.sourcePath',      1 },
		{ '%^source',            'event.source',          1 },
		{ '%^targetPathname',    'event.targetPathname',  1 },
		{ '%^targetPathdir',     'event.targetPathdir',   1 },
		{ '%^targetPath',        'event.targetPath',      1 },
		{ '%^target',            'event.target',          1 },
		{ '%^o%.pathname',       'event.pathname',        1 },
		{ '%^o%.path',           'event.path',            1 },
		{ '%^o%.sourcePathname', 'event.sourcePathname',  1 },
		{ '%^o%.sourcePathdir',  'event.sourcePathdir',   1 },
		{ '%^o%.sourcePath',     'event.sourcePath',      1 },
		{ '%^o%.targetPathname', 'event.targetPathname',  1 },
		{ '%^o%.targetPathdir',  'event.targetPathdir',   1 },
		{ '%^o%.targetPath',     'event.targetPath',      1 },
		{ '%^d%.pathname',       'event2.pathname',       2 },
		{ '%^d%.path',           'event2.path',           2 },
		{ '%^d%.sourcePathname', 'event2.sourcePathname', 2 },
		{ '%^d%.sourcePathdir',  'event2.sourcePathdir',  2 },
		{ '%^d%.sourcePath',     'event2.sourcePath',     2 },
		{ '%^d%.targetPathname', 'event2.targetPathname', 2 },
		{ '%^d%.targetPathdir',  'event2.targetPathdir',  2 },
		{ '%^d%.targetPath',     'event2.targetPath',     2 },
	}

	--
	-- Splits a user string into its arguments.
	-- Returns a table of arguments
	--
	local function splitStr(
		str -- a string where parameters are seperated by spaces.
	)
		local args = { }

		while str ~= ''
		do
			-- break where argument stops
			local bp = #str

			-- in a quote
			local inQuote = false

			-- tests characters to be space and not within quotes
			for i = 1, #str
			do
				local c = string.sub( str, i, i )

				if c == '"'
				then
					inQuote = not inQuote
				elseif c == ' ' and not inQuote
				then
					bp = i - 1

					break
				end
			end

			local arg = string.sub( str, 1, bp )
			arg = string.gsub( arg, '"', '\\"' )
			table.insert( args, arg )
			str = string.sub( str, bp + 1, -1 )
			str = string.match( str, '^%s*(.-)%s*$' )

		end

		return args
	end


	--
	-- Translates a call to a binary to a lua function.
	-- TODO this has a little too blocking.
	--
	local function translateBinary
	(
		str
	)
		-- splits the string
		local args = splitStr( str )

		-- true if there is a second event
		local haveEvent2 = false

		for ia, iv in ipairs( args )
		do
			-- a list of arguments this arg is being split into
			local a = { { true, iv } }

			-- goes through all translates
			for _, v in ipairs( transVars )
			do
				local ai = 1
				while ai <= #a
				do
					if a[ ai ][ 1 ]
					then
						local pre, post =
							string.match( a[ ai ][ 2 ], '(.*)'..v[1]..'(.*)' )

						if pre
						then
							if v[3] > 1
							then
								haveEvent2 = true
							end

							if pre ~= ''
							then
								table.insert( a, ai, { true, pre } )
								ai = ai + 1
							end

							a[ ai ] = { false, v[ 2 ] }

							if post ~= ''
							then
								table.insert( a, ai + 1, { true, post } )
							end
						end
					end
					ai = ai + 1
				end
			end

			-- concats the argument pieces into a string.
			local as = ''
			local first = true

			for _, v in ipairs( a )
			do
				if not first then as = as..' .. ' end

				if v[ 1 ]
				then
					as = as .. '"' .. v[ 2 ] .. '"'
				else
					as = as .. v[ 2 ]
				end

				first = false
			end

			args[ ia ] = as
		end

		local ft

		if not haveEvent2
		then
			ft = 'function( event )\n'
		else
			ft = 'function( event, event2 )\n'
		end

		ft = ft ..
			"    log('Normal', 'Event ', event.etype, \n" ..
			"        ' spawns action \"".. str.."\"')\n" ..
			"    spawn( event"

		for _, v in ipairs( args )
		do
			ft = ft .. ',\n         ' .. v
		end

		ft = ft .. ')\nend'
		return ft

	end


	--
	-- Translates a call using a shell to a lua function
	--
	local function translateShell
	(
		str
	)
		local argn = 1

		local args = { }

		local cmd = str

		local lc = str

		-- true if there is a second event
		local haveEvent2 = false

		for _, v in ipairs( transVars )
		do
			local occur = false

			cmd = string.gsub(
				cmd,
				v[ 1 ],
				function
				( )
					occur = true
					return '"$' .. argn .. '"'
				end
			)

			lc = string.gsub( lc, v[1], ']]..' .. v[2] .. '..[[' )

			if occur
			then
				argn = argn + 1

				table.insert( args, v[ 2 ] )

				if v[ 3 ] > 1
				then
					haveEvent2 = true
				end
			end

		end

		local ft

		if not haveEvent2
		then
			ft = 'function( event )\n'
		else
			ft = 'function( event, event2 )\n'
		end

		-- TODO do array joining instead
		ft = ft..
			"    log('Normal', 'Event ',event.etype,\n"..
			"        [[ spawns shell \""..lc.."\"]])\n"..
			"    spawnShell(event, [["..cmd.."]]"

		for _, v in ipairs( args )
		do
			ft = ft..',\n         '..v
		end

		ft = ft .. ')\nend'

		return ft

	end

	--
	-- Writes a lua function for a layer 3 user script.
	--
	local function translate
	(
		str
	)
		-- trims spaces
		str = string.match( str, '^%s*(.-)%s*$' )

		local ft

		if string.byte( str, 1, 1 ) == 47
		then
			-- starts with /
			 ft = translateBinary( str )
		elseif string.byte( str, 1, 1 ) == 94
		then
			-- starts with ^
			 ft = translateShell( str:sub( 2, -1 ) )
		else
			 ft = translateShell( str )
		end

		log( 'FWrite', 'translated "', str, '" to \n', ft )

		return ft
	end


	--
	-- Public interface.
	--
	return { translate = translate }

end )( )



--
-- Writes a status report file at most every 'statusintervall' seconds.
--
local StatusFile = ( function
( )
	--
	-- Timestamp when the status file has been written.
	--
	local lastWritten = false

	--
	-- Timestamp when a status file should be written.
	--
	local alarm = false

	--
	-- Returns the alarm when the status file should be written-
	--
	local function getAlarm
	( )
		return alarm
	end

	--
	-- Called to check if to write a status file.
	--
	local function write
	(
		timestamp
	)
		log( 'Function', 'write( ', timestamp, ' )' )

		--
		-- takes care not to write too often
		--
		if uSettings.statusInterval > 0
		then
			-- already waiting?
			if alarm and timestamp < alarm
			then
				log( 'Statusfile', 'waiting(', timestamp, ' < ', alarm, ')' )

				return
			end

			-- determines when a next write will be possible
			if not alarm
			then
				local nextWrite = lastWritten and timestamp + uSettings.statusInterval

				if nextWrite and timestamp < nextWrite
				then
					log( 'Statusfile', 'setting alarm: ', nextWrite )
					alarm = nextWrite

					return
				end
			end

			lastWritten = timestamp
			alarm = false
		end

		log( 'Statusfile', 'writing now' )

		local f, err = io.open( uSettings.statusFile, 'w' )

		if not f
		then
			log(
				'Error',
				'Cannot open status file "' ..
					uSettings.statusFile ..
					'" :' ..
					err
			)
			return
		end

		f:write( 'Lsyncd status report at ', os.date( ), '\n\n' )

		for i, s in SyncMaster.iwalk( )
		do
			s:statusReport( f )

			f:write( '\n' )
		end

		Inotify.statusReport( f )

		f:close( )
	end

	--
	-- Public interface
	--
	return { write = write, getAlarm = getAlarm }
end )( )


--
-- Lets userscripts make their own alarms.
--
local UserAlarms = ( function
( )
	local alarms = { }

	--
	-- Calls the user function at timestamp.
	--
	local function alarm
	(
		timestamp,
		func,
		extra
	)
		local idx

		for k, v in ipairs( alarms )
		do
			if timestamp < v.timestamp
			then
				idx = k

				break
			end
		end

		local a =
		{
			timestamp = timestamp,
			func = func,
			extra = extra
		}

		if idx
		then
			table.insert( alarms, idx, a )
		else
			table.insert( alarms, a )
		end
	end


	--
	-- Retrieves the soonest alarm.
	--
	local function getAlarm
	( )
		if #alarms == 0
		then
			return false
		else
			return alarms[1].timestamp
		end
	end


	--
	-- Calls user alarms.
	--
	local function invoke
	(
		timestamp
	)
		while #alarms > 0
		and alarms[ 1 ].timestamp <= timestamp
		do
			alarms[ 1 ].func( alarms[ 1 ].timestamp, alarms[ 1 ].extra )
			table.remove( alarms, 1 )
		end
	end


	--
	-- Public interface
	--
	return {
		alarm    = alarm,
		getAlarm = getAlarm,
		invoke   = invoke
	}

end )( )


--============================================================================
-- Mantle core interface. These functions are called from core.
--============================================================================


--
-- Current status of Lsyncd.
--
-- 'init'  ... on (re)init
-- 'run'   ... normal operation
-- 'fade'  ... waits for remaining processes
--
local lsyncdStatus = 'init'

--
-- The mantle cores interface
--
mci = { }


--
-- Last time said to be waiting for more child processes
--
local lastReportedWaiting = false

--
-- Called from core whenever Lua code failed.
--
-- Logs a backtrace
--
function mci.callError
(
	message
)
	core.log( 'Error', 'in Lua: ', message )

	-- prints backtrace
	local level = 2

	while true
	do
		local info = debug.getinfo( level, 'Sl' )

		if not info then terminate( -1 ) end

		log(
			'Error',
			'Backtrace ',
			level - 1, ' :',
			info.short_src, ':',
			info.currentline
		)

		level = level + 1
	end
end


-- Registers the mantle with the core
core.mci( mci )


--
-- Called from core whenever a child process has finished and
-- the zombie process was collected by core.
--
function mci.collectProcess
(
	pid,       -- process id
	exitcode   -- exitcode
)
	processCount = processCount - 1

	if processCount < 0
	then
		error( 'negative number of processes!' )
	end

	for _, s in SyncMaster.iwalk( )
	do
		if s:collect( pid, exitcode ) then return end
	end
end

--
-- Called from core everytime a masterloop cycle runs through.
--
-- This happens in case of
--   * an expired alarm.
--   * a returned child process.
--   * received filesystem events.
--   * received a HUP, TERM or INT signal.
--
function mci.cycle(
	timestamp   -- the current kernel time (in jiffies)
)
	log( 'Function', 'cycle( ', timestamp, ' )' )

	if lsyncdStatus == 'fade'
	then
		if processCount > 0
		then
			if lastReportedWaiting == false
			or timestamp >= lastReportedWaiting + 60
			then
				lastReportedWaiting = timestamp

				log( 'Normal', 'waiting for ', processCount, ' more child processes.' )
			end

			return true
		else
			return false
		end
	end

	if lsyncdStatus ~= 'run'
	then
		error( 'mci.cycle() called while not running!' )
	end

	--
	-- Goes through all syncs and spawns more actions
	-- if possibly. But only lets SyncMaster invoke actions if
	-- not at global limit.
	--
	if not uSettings.maxProcesses
	or processCount < uSettings.maxProcesses
	then
		local start = SyncMaster.getRound( )

		local ir = start

		repeat
			local s = SyncMaster.get( ir )

			s:invokeActions( timestamp )

			ir = ir + 1

			if ir >= #SyncMaster then ir = 0 end
		until ir == start

		SyncMaster.nextRound( )
	end

	UserAlarms.invoke( timestamp )

	if uSettings.statusFile
	then
		StatusFile.write( timestamp )
	end

	return true
end

--
-- Called by core if '-help' or '--help' is in
-- the arguments.
--
function mci.help( )
	io.stdout:write(
[[

USAGE:
 lsyncd [OPTIONS] [CONFIG-FILE]

OPTIONS:
  -delay SECS         Overrides default delay times
  -help               Shows this
  -log    all         Logs everything (debug)
  -log    scarce      Logs errors only
  -log    [Category]  Turns on logging for a debug category
  -logfile FILE       Writes log to FILE (DEFAULT: uses syslog)
  -version            Prints versions and exits

LICENSE:
  GPLv2 or any later version.

SEE:
  `man lsyncd` or visit https://axkibe.github.io/lsyncd/ for further information.
]])

	os.exit( -1 )
end


--
-- Called from core to parse the command line arguments
--
-- returns a string as user script to load.
--    or simply 'true' if running with rsync bevaiour
--
-- terminates on invalid arguments.
--
function mci.configure( args, monitors )

	Monitors.initialize( monitors )

	--
	-- a list of all valid options
	--
	-- first paramter is the number of parameters an option takes
	-- if < 0 the called function has to check the presence of
	-- optional arguments.
	--
	-- second paramter is the function to call
	--
	local options =
	{
		-- log is handled by core already.

		delay =
		{
			1,
			function
			(
				secs
			)
				clSettings.delay = secs + 0
			end
		},

		log = { 1, nil },

		logfile =
		{
			1,
			function
			(
				file
			)
				clSettings.logfile = file
			end
		},

		version =
		{
			0,
			function
			( )
				io.stdout:write( 'Version: ', lsyncd_version, '\n' )

				os.exit( 0 )
			end
		}
	}

	-- non-opts is filled with all args that were no part dash options
	local nonopts = { }

	local i = 1

	while i <= #args
	do
		local a = args[ i ]

		if a:sub( 1, 1 ) ~= '-'
		then
			table.insert( nonopts, args[ i ] )
		else
			if a:sub( 1, 2 ) == '--'
			then
				a = a:sub( 3 )
			else
				a = a:sub( 2 )
			end

			local o = options[ a ]

			if not o
			then
				log( 'Error', 'unknown option command line option ', args[ i ] )

				os.exit( -1 )
			end

			if o[ 1 ] >= 0 and i + o[ 1 ] > #args
			then
				log( 'Error', a ,' needs ', o[ 1 ],' arguments' )

				os.exit( -1 )
			elseif o[1] < 0
			then
				o[ 1 ] = -o[ 1 ]
			end

			if o[ 2 ]
			then
				if o[ 1 ] == 0
				then
					o[ 2 ]( )
				elseif o[ 1 ] == 1
				then
					o[ 2 ]( args[ i + 1] )
				elseif o[ 1 ] == 2
				then
					o[ 2 ]( args[ i + 1], args[ i + 2] )
				elseif o[ 1 ] == 3
				then
					o[ 2 ]( args[ i + 1], args[ i + 2], args[ i + 3] )
				end
			end

			i = i + o[1]
		end

		i = i + 1
	end

	if #nonopts == 0
	then
		mci.help( args[ 0 ] )
	elseif #nonopts == 1
	then
		return nonopts[ 1 ]
	else
		-- TODO make this possible
		log( 'Error', 'There can only be one config file in the command line.' )

		os.exit( -1 )
	end
end


--
-- Called from core on init or restart after user configuration.
--
-- firstTime:
--    true when Lsyncd startups the first time,
--    false on resets, due to HUP signal or monitor queue overflow.
--
function mci.initialize( firstTime )

	-- Checks if user overwrote the settings function.
	-- ( was Lsyncd <2.1 style )
	if userENV.settings ~= settings
	then
		log(
			'Error',
			'Do not use settings = { ... }\n'..
			'      please use settings{ ... } ( without the equal sign )'
		)

		os.exit( -1 )
	end

	lastReportedWaiting = false

	--
	-- From this point on, no globals may be created anymore
	--
	lockGlobals( )

	--
	-- all command line settings overwrite config file settings
	--
	for k, v in pairs( clSettings )
	do
		if k ~= 'syncs'
		then
			uSettings[ k ] = v
		end
	end

	if uSettings.logfile
	then
		core.configure( 'logfile', uSettings.logfile )
	end

	if uSettings.logident
	then
		core.configure( 'logident', uSettings.logident )
	end

	if uSettings.logfacility
	then
		core.configure( 'logfacility', uSettings.logfacility )
	end

	--
	-- Transfers some defaults to uSettings
	--
	if uSettings.statusInterval == nil
	then
		uSettings.statusInterval = default.statusInterval
	end

	-- makes sure the user gave Lsyncd anything to do
	if #SyncMaster == 0
	then
		log( 'Error', 'Nothing to watch!' )
		os.exit( -1 )
	end

	-- from now on use logging as configured instead of stdout/err.
	lsyncdStatus = 'run';

	core.configure( 'running' );

	local ufuncs =
	{
		'onAttrib',
		'onCreate',
		'onDelete',
		'onModify',
		'onMove',
		'onStartup',
	}

	-- translates layer 3 scripts
	for _, s in SyncMaster.iwalk()
	do
		-- checks if any user functions is a layer 3 string.
		local config = s.config

		for _, fn in ipairs( ufuncs )
		do
			if type(config[fn]) == 'string'
			then
				local ft = functionWriter.translate( config[ fn ] )

				config[ fn ] = assert( load( 'return '..ft ) )( )
			end
		end
	end

	-- runs through the Syncs created by users
	for _, s in SyncMaster.iwalk( )
	do
		if s.config.monitor == 'inotify'
		then
			Inotify.addSync( s, s.source )
		else
			error( 'sync '.. s.config.name..' has unknown event monitor interface.' )
		end

		-- if the sync has an init function, the init delay
		-- is stacked which causes the init function to be called.
		if s.config.init
		then
			s:addInitDelay( )
		end
	end
end

--
-- Called by core to query the soonest alarm.
--
-- @return false ... no alarm, core can go in untimed sleep
--         true  ... immediate action
--         times ... the alarm time (only read if number is 1)
--
function mci.getAlarm
( )
	log( 'Function', 'getAlarm( )' )

	if lsyncdStatus ~= 'run' then return false end

	local alarm = false

	--
	-- Checks if 'a' is sooner than the 'alarm' up-value.
	--
	local function checkAlarm
	(
		a  -- alarm time
	)
		if a == nil then error( 'got nil alarm' ) end

		if alarm == true or not a
		then
			-- 'alarm' is already immediate or
			-- a not a new alarm
			return
		end

		-- sets 'alarm' to a if a is sooner
		if not alarm or a < alarm
		then
			alarm = a
		end
	end

	--
	-- checks all syncs for their earliest alarm,
	-- but only if the global process limit is not yet reached.
	--
	if not uSettings.maxProcesses
	or processCount < uSettings.maxProcesses
	then
		for _, s in SyncMaster.iwalk( )
		do
			checkAlarm( s:getAlarm( ) )
		end
	else
		log(
			'Alarm',
			'at global process limit.'
		)
	end

	-- checks if a statusfile write has been delayed
	checkAlarm( StatusFile.getAlarm( ) )

	-- checks for an userAlarm
	checkAlarm( UserAlarms.getAlarm( ) )

	log( 'Alarm', 'mci.getAlarm returns: ', alarm )

	return alarm
end


--
-- Called when an file system monitor events arrive
--
mci.inotifyEvent = Inotify.event

--
-- Collector for every child process that finished in startup phase
--
function mci.collector
(
	pid,       -- pid of the child process
	exitcode   -- exitcode of the child process
)
	if exitcode ~= 0
	then
		log( 'Error', 'Startup process', pid, ' failed' )

		terminate( -1 )
	end

	return 0
end

--
-- Called by core when an overflow happened.
--
function mci.overflow
( )
	log( 'Normal', '--- OVERFLOW in event queue ---' )

	lsyncdStatus = 'fade'
end

--
-- Called by core on a hup signal.
--
function mci.hup
( )
	log( 'Normal', '--- HUP signal, resetting ---' )

	lsyncdStatus = 'fade'
end

--
-- Called by core on a term signal.
--
function mci.term
(
	sigcode  -- signal code
)
	local sigtexts =
	{
		[ 2 ] = 'INT',
		[ 15 ] = 'TERM'
	};

	local sigtext = sigtexts[ sigcode ];

	if not sigtext then sigtext = 'UNKNOWN' end

	log( 'Normal', '--- ', sigtext, ' signal, fading ---' )

	lsyncdStatus = 'fade'

end


--============================================================================
-- Lsyncd runner's user interface
--============================================================================


--
-- Main utility to create new observations.
--
-- Returns an Inlet to that sync.
--
function sync
(
	opts
)
	if lsyncdStatus ~= 'init'
	then
		error( 'Sync can only be created during initialization.', 2 )
	end

	return SyncMaster.add( opts ).inlet
end


--
-- Spawns a new child process.
--
function spawn
(
	agent,  -- the reason why a process is spawned.
	        -- a delay or delay list for a sync
	        -- it will mark the related files as blocked.
	binary, -- binary to call
	...     -- arguments
)
	if agent == nil
	or type( agent ) ~= 'table'
	then
		error( 'spawning with an invalid agent', 2 )
	end

	if lsyncdStatus == 'fade'
	then
		log( 'Normal', 'ignored process spawning while fading' )
		return
	end

	if type( binary ) ~= 'string'
	then
		error( 'calling spawn(agent, binary, ...): binary is not a string', 2 )
	end

	local dol = InletFactory.getDelayOrList( agent )

	if not dol
	then
		error( 'spawning with an unknown agent', 2 )
	end

	--
	-- checks if a spawn is called on an already active event
	--
	if dol.status
	then
		-- is an event

		if dol.status ~= 'wait'
		then
			error( 'spawn() called on an non-waiting event', 2 )
		end
	else
		-- is a list
		for _, d in ipairs( dol )
		do
			if d.status ~= 'wait'
			and d.status ~= 'block'
			then
				error( 'spawn() called on an non-waiting event list', 2 )
			end
		end
	end

	--
	-- tries to spawn the process
	--
	local pid = core.exec( binary, ... )

	if pid and pid > 0
	then
		processCount = processCount + 1

		if uSettings.maxProcesses
		and processCount > uSettings.maxProcesses
		then
			error( 'Spawned too much processes!' )
		end

		local sync = InletFactory.getSync( agent )

		-- delay or list
		if dol.status
		then
			-- is a delay
			dol:setActive( )

			sync.processes[ pid ] = dol
		else
			-- is a list
			for _, d in ipairs( dol )
			do
				d:setActive( )
			end

			sync.processes[ pid ] = dol
		end
	end
end

--
-- Spawns a child process using the default shell.
--
function spawnShell
(
	agent,     -- the delay(list) to spawn the command for
	command,   -- the shell command
	...        -- additonal arguments
)
	return spawn( agent, '/bin/sh', '-c', command, '/bin/sh', ... )
end


--
-- Observes a filedescriptor.
--
function observefd
(
	fd,     -- file descriptor
	ready,  -- called when fd is ready to be read
	writey  -- called when fd is ready to be written
)
	return core.observe_fd( fd, ready, writey )
end


--
-- Stops observeing a filedescriptor.
--
function nonobservefd
(
	fd      -- file descriptor
)
	return core.nonobserve_fd( fd )
end


--
-- Calls func at timestamp.
--
-- Use now() to receive current timestamp
-- add seconds with '+' to it
--
alarm = UserAlarms.alarm


--
-- Comfort routine, also for user.
-- Returns true if 'String' starts with 'Start'
--
function string.starts
(
	String,
	Start
)
	return string.sub( String, 1, #Start ) == Start
end


--
-- Comfort routine, also for user.
-- Returns true if 'String' ends with 'End'
--
function string.ends
(
	String,
	End
)
	return End == '' or string.sub( String, -#End ) == End
end


--
-- The settings call
--
function settings
(
	a1  -- a string for getting a setting
	--     or a table of key/value pairs to set these settings
)

	-- if a1 is a string this is a get operation
	if type( a1 ) == 'string'
	then
		return uSettings[ a1 ]
	end

	-- if its a table it sets all the value of the bale
	for k, v in pairs( a1 )
	do
		if type( k ) ~= 'number'
		then
			if not settingsCheckgauge[ k ]
			then
				error( 'setting "'..k..'" unknown.', 2 )
			end

			uSettings[ k ] = v
		else
			if not settingsCheckgauge[ v ]
			then
				error( 'setting "'..v..'" unknown.', 2 )
			end

			uSettings[ v ] = true
		end
	end
end

