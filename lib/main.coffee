# This program is suited only to manage your cozy installation from the inside
# Moreover app management works only for apps make by Cozy Cloud company.
# If you want a friendly application manager you should use the
# appmanager.coffee script.

require "colors"

program = require 'commander'
async = require "async"
fs = require "fs"
axon = require 'axon'
exec = require('child_process').exec
spawn = require('child_process').spawn
path = require('path')
log = require('printit')()

request = require("request-json-light")
ControllerClient = require("cozy-clients").ControllerClient

pkg = require '../package.json'
version = pkg.version

couchUrl = "http://localhost:5984/"
dataSystemUrl = "http://localhost:9101/"
indexerUrl = "http://localhost:9102/"
controllerUrl = "http://localhost:9002/"
homeUrl = "http://localhost:9103/"
proxyUrl = "http://localhost:9104/"
postfixUrl = "http://localhost:25/"

homeClient = request.newClient homeUrl
statusClient = request.newClient ''
couchClient = request.newClient couchUrl
dsClient = request.newClient dataSystemUrl
appsPath = '/usr/local/cozy/apps'



## Helpers

# Generate a random 32 char string.
randomString = (length=32) ->
    string = ""
    string += Math.random().toString(36).substr(2) while string.length < length
    string.substr 0, length


# Read Controller auth token from token file located in /etc/cozy/stack.token .
readToken = (file) ->
    try
        token = fs.readFileSync file, 'utf8'
        token = token.split('\n')[0]
        return token
    catch err
        log.info """
Cannot get Cozy credentials. Are you sure you have the rights to access to:
/etc/cozy/stack.token ?
"""
        return null


# Get Controller auth token from token file. If it can't find token in
# expected folder it looks for in the location of previous controller version
# (backward compatibility).
getToken = ->

    # New controller
    if fs.existsSync '/etc/cozy/stack.token'
        return readToken '/etc/cozy/stack.token'
    else

        # Old controller
        if fs.existsSync '/etc/cozy/controller.token'
            return readToken '/etc/cozy/controller.token'
        else
            return null


getAuthCouchdb = (callback) ->
    try
        data = fs.readFileSync '/etc/cozy/couchdb.login', 'utf8', (err, data) =>
        username = data.split('\n')[0]
        password = data.split('\n')[1]
        return [username, password]
    catch err
        console.log err
        log.error """
Cannot read database credentials in /etc/cozy/couchdb.login.
"""
        process.exit 1


handleError = (err, body, msg) ->
    log.error "An error occured:"
    log.raw err if err
    log.raw msg
    if body?
        if body.msg?
            log.raw body.msg
        else if body.error?
            log.raw body.error.message if body.error.message?
            log.raw body.message if body.message?
            log.raw body.error.result if body.error.result?
            log.raw "Request error code #{body.error.code}" if body.error.code?
            log.raw body.error.blame if body.error.blame?
            log.raw body.error if typeof body.error is "string"
        else log.raw body
    process.exit 1


compactViews = (database, designDoc, callback) ->
    [username, password] = getAuthCouchdb()
    couchClient.setBasicAuth username, password
    path = "#{database}/_compact/#{designDoc}"
    couchClient.headers['content-type'] = 'application/json'
    couchClient.post path, {}, (err, res, body) =>
        if err or not body.ok
            handleError err, body, "compaction failed for #{designDoc}"
        else
            callback null


compactAllViews = (database, designs, callback) ->
    if designs.length > 0
        design = designs.pop()
        log.info "Views compaction for #{design}"
        compactViews database, design, (err) =>
            compactAllViews database, designs, callback
    else
        callback null


configureCouchClient = (callback) ->
    [username, password] = getAuthCouchdb()
    couchClient.setBasicAuth username, password


waitCompactComplete = (client, found, callback) ->
    setTimeout ->
        client.get '_active_tasks', (err, res, body) =>
            exist = false
            for task in body
                if task.type is "database_compaction"
                    exist = true
            if (not exist) and found
                callback true
            else
                waitCompactComplete(client, exist, callback)
    , 500


waitInstallComplete = (slug, callback) ->
    axon   = require 'axon'
    socket = axon.socket 'sub-emitter'
    socket.connect 9105
    noAppListErrMsg = """
No application listed after installation.
"""
    appNotStartedErrMsg = """
Application is not running after installation.
"""
    appNotListedErrMsg = """
Expected application not listed in database after installation.
"""

    timeoutId = setTimeout ->
        socket.close()

        statusClient.host = homeUrl
        statusClient.get "api/applications/", (err, res, apps) ->
            if not apps?.rows?
                callback new Error noAppListErrMsg
            else
                isApp = false

                for app in apps.rows

                    if app.slug is slug and \
                       app.state is 'installed' and \
                       app.port

                        isApp = true
                        statusClient.host = "http://localhost:#{app.port}/"
                        statusClient.get "", (err, res) ->
                            if res?.statusCode in [200, 403]
                                callback null, state: 'installed'
                            else
                                callback new Error appNotStartedErrMsg

                unless isApp
                    callback new Error appNotListedErrMsg
    , 240000

    socket.on 'application.update', (id) ->
        clearTimeout timeoutId
        socket.close()

        dSclient = request.newClient dataSystemUrl
        dSclient.setBasicAuth 'home', token if token = getToken()
        dSclient.get "data/#{id}/", (err, response, body) ->
            if response.statusCode is 401
                dSclient.setBasicAuth 'home', ''
                dSclient.get "data/#{id}/", (err, response, body) ->
                    callback err, body
            else
                callback err, body


prepareCozyDatabase = (username, password, callback) ->
    couchClient.setBasicAuth username, password

    # Remove cozy database
    couchClient.del "cozy", (err, res, body) ->
        # Create new cozy database
        couchClient.put "cozy", {}, (err, res, body) ->
            # Add member in cozy database
            data =
                "admins":
                    "names":[username]
                    "roles":[]
                "readers":
                    "names":[username]
                    "roles":[]
            couchClient.put 'cozy/_security', data, (err, res, body)->
                if err?
                    console.log err
                    process.exit 1
                callback()


getVersion = (name) =>
    if name is "controller"
        path = "/usr/local/lib/node_modules/cozy-controller/package.json"
    else
        path = "#{appsPath}/#{name}/#{name}/cozy-#{name}/package.json"
    if fs.existsSync path
        data = fs.readFileSync path, 'utf8'
        data = JSON.parse data
        log.raw "#{name}: #{data.version}"
    else
        if name is 'controller'
            path = "/usr/lib/node_modules/cozy-controller/package.json"
        else
            path = "#{appsPath}/#{name}/package.json"
        if fs.existsSync path
            data = fs.readFileSync path, 'utf8'
            data = JSON.parse data
            log.raw "#{name}: #{data.version}"
        else
            log.raw "#{name}: unknown"


getVersionIndexer = (callback) =>
    client = request.newClient indexerUrl
    client.get '', (err, res, body) =>
        if body? and body.split('v')[1]?
            callback  body.split('v')[1]
        else
            callback "unknown"


startApp = (app, callback) ->
    path = "api/applications/#{app.slug}/start"
    homeClient.post path, app, (err, res, body) ->
        if err
            callback err
        else if body.error
            callback body.error
        else
            callback()


removeApp = (app, callback) ->
    path = "api/applications/#{app.slug}/uninstall"
    homeClient.del path, (err, res, body) ->
        if err
            callback err, body
        else if body.error
            callback body.error, body
        else
            callback()


installStackApp = (app, callback) ->
    if typeof app is 'string'
        manifest =
            repository:
                url: "https://github.com/cozy/cozy-#{app}.git"
                type: "git"
            "scripts":
                "start": "build/server.js"
            name: app
            user: app
    else
        manifest = app
    log.info "Install started for #{manifest.name}..."
    client.clean manifest, (err, res, body) ->
        client.start manifest, (err, res, body)  ->
            if err or body.error?
                handleError err, body, "Install failed for #{manifest.name}."
            else
                log.info "#{manifest.name} was successfully installed."
                callback null


installApp = (app, callback) ->
    manifest =
        "domain": "localhost"
        "repository":
            "type": "git"
        "scripts":
            "start": "server.coffee"
        "name": app.name
        "displayName":  app.displayName
        "user": app.name
        "git": app.git
    if app.branch?
        manifest.repository.branch = app.branch
    path = "api/applications/install"
    homeClient.headers['content-type'] = 'application/json'
    homeClient.post path, manifest, (err, res, body) ->
        if err
            callback err
        else if body?.error
            callback body.error
        else
            waitInstallComplete app.slug, (err, appresult) ->
                if err
                    callback err
                else
                    callback()


stopApp = (app, callback) ->
    path = "api/applications/#{app.slug}/stop"
    homeClient.post path, app, (err, res, body) ->
        if err
            callback err
        else if body.error
            callback body.error
        else
            callback()


token = getToken()
client = new ControllerClient
    token: token


manifest =
   "domain": "localhost"
   "repository":
       "type": "git"
   "scripts":
       "start": "server.coffee"


program
  .version(version)
  .usage('<action> <app>')


## Applications management ##

# Install
#
program
    .command("install <app> ")
    .description("Install application")
    .option('-r, --repo <repo>', 'Use specific repo')
    .option('-b, --branch <branch>', 'Use specific branch')
    .option('-d, --displayName <displayName>', 'Display specific name')
    .action (app, options) ->
        # Create manifest
        manifest.name = app
        if options.displayName?
            manifest.displayName = options.displayName
        else
            manifest.displayName = app
        manifest.user = app

        # Check if it is a stack or classic application
        if app in ['data-system', 'home', 'proxy']

            unless options.repo?
                manifest.repository.url =
                    "https://github.com/cozy/cozy-#{app}.git"
            else
                manifest.repository.url = options.repo
            if options.branch?
                manifest.repository.branch = options.branch
            installStackApp manifest, (err) ->
                    if err
                        handleError err, null, "Install failed"
                    else
                        log.info "#{app} successfully installed"

        else

            log.info "Install started for #{app}..."
            unless options.repo?
                manifest.git =
                    "https://github.com/cozy/cozy-#{app}.git"

            else
                manifest.git = options.repo

            if options.branch?
                manifest.branch = options.branch
            path = "api/applications/install"
            homeClient.post path, manifest, (err, res, body) ->
                if err or body.error
                    if err?.code is 'ECONNREFUSED'
                        msg = """
Install home failed for #{app}.
The Cozy Home looks not started. Install operation cannot be performed.
"""
                        handleError err, body, msg
                    else if body?.message?.indexOf('Not Found') isnt -1
                        msg = """
Install home failed for #{app}.
Default git repo #{manifest.git} doesn't exist.
You can use option -r to use a specific repo."""
                        handleError err, body, msg
                    else
                        handleError err, body, "Install home failed for #{app}."

                else
                    waitInstallComplete body.app.slug, (err, appresult) ->
                        if err
                            msg = "Install home failed."
                            handleError err, null, msg
                        else if appresult.state is 'installed'
                            log.info "#{app} was successfully installed."
                        else if appresult.state is 'installing'
                            log.info """
#{app} installation is still running. You should check for its status later.
If the installation is too long, you should try to stop it by uninstalling the
application and running the installation again.
"""
                        else
                            msg = """
Install home failed. Can't figure out the app state.
"""
                            handleError err, null, msg

# Install cozy stack (home, ds, proxy)
program
    .command("install-cozy-stack")
    .description("Install cozy via the Cozy Controller")
    .action () ->
        installStackApp 'data-system', () ->
            installStackApp 'home', () ->
                installStackApp 'proxy', () ->
                    log.info 'Cozy stack successfully installed.'


# Uninstall
program
    .command("uninstall <app>")
    .description("Remove application")
    .action (app) ->
        log.info "Uninstall started for #{app}..."
        if app in ['data-system', 'home', 'proxy']
            manifest.name = app
            manifest.user = app
            client.clean manifest, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Uninstall failed for #{app}."
                else
                    log.info "#{app} was successfully uninstalled."
        else
            removeApp "name": app, (err, body)->
                if err
                    handleError err, body, "Uninstall home failed for #{app}."
                else
                    log.info "#{app} was successfully uninstalled."


# Start
program
    .command("start <app>")
    .description("Start application")
    .action (app) ->
        log.info "Starting #{app}..."
        if app in ['data-system', 'home', 'proxy']
            manifest.name = app
            manifest.repository.url =
                "https://github.com/cozy/cozy-#{app}.git"
            manifest.user = app
            client.stop app, (err, res, body) ->
                client.start manifest, (err, res, body) ->
                    if err or body.error?
                        handleError err, body, "Start failed for #{app}."
                    else
                        log.info "#{app} was successfully started."
        else
            find = false
            homeClient.host = homeUrl
            homeClient.get "api/applications/", (err, res, apps) ->
                if apps? and apps.rows?
                    for manifest in apps.rows when manifest.name is app
                        find = true
                        startApp manifest, (err) ->
                            if err
                                handleError err, null, "Start failed for #{app}."
                            else
                                log.info "#{app} was successfully started."
                    unless find
                        log.error "Start failed : application #{app} not found."
                else
                    log.error "Start failed : no applications installed."


program
    .command("force-restart")
    .description("Force application restart - usefull for relocation")
    .action () ->
        restart = (app, callback) ->
            # Start function in home restart application
            startApp app, (err) ->
                if err
                    log.error "Restart failed"
                else
                    log.info "... successfully"
                callback()

        restop = (app, callback) ->
            startApp app, (err) ->
                if err
                    log.error "Stop failed for #{app}."
                else
                    stopApp app, (err) ->
                        if err
                            log.error "Start failed for #{app}."
                        else
                            log.info "... successfully"
                            callback()

        reinstall = (app, callback) ->
            removeApp app, (err) ->
                if err
                    msg = "Uninstall failed for #{app}."
                else
                    installApp app, (err) ->
                        if err
                            msg = "Install failed for #{app}."
                        else
                            log.info "... successfully"
                            callback()

        homeClient.get "api/applications/", (err, res, apps) ->
            funcs = []
            if apps? and apps.rows?
                async.forEachSeries apps.rows, (app, callback) ->
                    switch app.state
                        when 'installed'
                            log.info "Restart #{app.slug}..."
                            restart app, callback
                        when 'stopped'
                            log.info "Restop #{app.slug}..."
                            restop app, callback
                        when 'installing'
                            log.info "Reinstall #{app.slug}..."
                            reinstall app, callback
                        when 'broken'
                            log.info "Reinstall #{app.slug}..."
                            reinstall app, callback
                        else
                            callback()


## Start applicationn without controller in a production environment.
# * Add/Replace application in database (for home and proxy)
# * Reset proxy
# * Start application with environment variable
# * When application is stopped : remove application in database and reset proxy
program
    .command("start-standalone <port>")
    .description("Start application without controller")
    .action (port) ->
        id = 0

        # Remove from database when process exit.
        removeFromDatabase = ->
            log.info "Remove application from database ..."
            dsClient.del "data/#{id}/", (err, response, body) ->
                statusClient.host = proxyUrl
                statusClient.get "routes/reset", (err, res, body) ->
                    if err
                        handleError err, body, "Cannot reset routes."
                    else
                        log.info "Reset proxy succeeded."
        process.on 'SIGINT', ->
            removeFromDatabase()
        process.on 'uncaughtException', (err) ->
            log.error 'uncaughtException'
            log.raw err
            removeFromDatabase()

        recoverManifest = (callback) ->
            unless fs.existsSync 'package.json'
                log.error "Cannot read package.json. " +
                    "This function should be called in root application folder."
            else
                try
                    packagePath = path.relative __dirname, 'package.json'
                    manifest = require packagePath
                catch err
                    log.raw err
                    log.error "Package.json isn't correctly formatted."
                    return

                # Retrieve manifest from package.json
                manifest.name = "#{manifest.name}test"
                manifest.permissions = manifest['cozy-permissions']
                manifest.displayName =
                    manifest['cozy-displayName'] or manifest.name
                manifest.state = "installed"
                manifest.password = randomString()
                manifest.docType = "Application"
                manifest.port = port
                manifest.slug = manifest.name.replace 'cozy-', ''

                if manifest.slug in ['hometest', 'proxytest', 'data-systemtest']
                    log.error(
                        'Sorry, cannot start stack application without ' +
                        ' controller.')
                else
                    callback(manifest)


        putInDatabase = (manifest, callback) ->
            log.info "Add/replace application in database..."
            token = getToken()
            if token?
                dsClient.setBasicAuth 'home', token
                requestPath = "request/application/all/"
                dsClient.post requestPath, {}, (err, response, apps) ->
                    if err
                        log.error "Data-system looks down (not responding)."
                    else
                        removeApp apps, manifest.name, () ->
                            dsClient.post "data/", manifest, (err, res, body) ->
                                id = body._id
                                if err
                                    msg = "Cannot add application in database."
                                    handleError err, body, msg
                                else
                                    callback()


        removeApp = (apps, name, callback) ->
            if apps.length > 0
                app = apps.pop().value
                if app.name is name
                    dsClient.del "data/#{app._id}/", (err, response, body) ->
                        removeApp apps, name, callback
                else
                    removeApp apps, name, callback
            else
                callback()

        log.info "Retrieve application manifest..."
        # Recover application manifest
        recoverManifest (manifest) ->
            # Add/Replace application in database
            putInDatabase manifest, () ->
                # Reset proxy
                log.info "Reset proxy..."
                statusClient.host = proxyUrl
                statusClient.get "routes/reset", (err, res, body) ->
                    if err
                        handleError err, body, "Cannot reset routes."
                    else
                        # Add environment varaible.
                        log.info "Start application..."
                        process.env.TOKEN = manifest.password
                        process.env.NAME = manifest.slug
                        process.env.NODE_ENV = "production"

                        # Start application
                        server = spawn "npm",  ["start"]
                        server.stdout.setEncoding 'utf8'
                        server.stdout.on 'data', (data) ->
                            log.raw data

                        server.stderr.setEncoding 'utf8'
                        server.stderr.on 'data', (data) ->
                            log.raw data
                        server.on 'error', (err) ->
                            log.raw err
                        server.on 'close', (code) ->
                            log.info "Process exited with code #{code}"


## Stop applicationn without controller in a production environment.
# * Remove application in database and reset proxy
# * Usefull if start-standalone doesn't remove app
program
    .command("stop-standalone")
    .description("Start application without controller")
    .action () ->
        removeApp = (apps, name, callback) ->
            if apps.length > 0
                app = apps.pop().value
                if app.name is name
                    dsClient.del "data/#{app._id}/", (err, response, body) =>
                        removeApp apps, name, callback
                else
                    removeApp apps, name, callback
            else
                callback()

        log.info "Retrieve application manifest ..."
        # Recover application manifest
        unless fs.existsSync 'package.json'
            log.error "Cannot read package.json. " +
                "This function should be called in root application  folder"
            return
        try
            packagePath = path.relative __dirname, 'package.json'
            manifest = require packagePath
        catch err
            log.raw err
            log.error "Package.json isn't in a correct format"
            return
        # Retrieve manifest from package.json
        manifest.name = manifest.name + "test"
        manifest.slug = manifest.name.replace 'cozy-', ''
        if manifest.slug in ['hometest', 'proxytest', 'data-systemtest']
            log.error 'Sorry, cannot start stack application without controller.'
        else
            # Add/Replace application in database
            token = getToken()
            unless token?
                return
            log.info "Remove from database ..."
            dsClient.setBasicAuth 'home', token
            requestPath = "request/application/all/"
            dsClient.post requestPath, {}, (err, response, apps) =>
                if err
                    log.error "Data-system doesn't respond"
                    return
                removeApp apps, manifest.name, () ->
                    log.info "Reset proxy ..."
                    statusClient.host = proxyUrl
                    statusClient.get "routes/reset", (err, res, body) ->
                        if err
                            handleError err, body, "Cannot reset routes."
                        else
                            log.info "Stop standalone finished with success"

# Stop

program
    .command("stop <app>")
    .description("Stop application")
    .action (app) ->
        log.info "Stopping #{app}..."
        if app in ['data-system', 'home', 'proxy']
            manifest.name = app
            manifest.user = app
            client.stop app, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Stop failed"
                else
                    log.info "#{app} was successfully stopped."
        else
            find = false
            homeClient.host = homeUrl
            homeClient.get "api/applications/", (err, res, apps) ->
                if apps?.rows?
                    for manifest in apps.rows when manifest.name is app
                        find = true
                        stopApp manifest, (err) ->
                            if err
                                handleError err, null, "Stop failed for #{app}."
                            else
                                log.info "#{app} was successfully stopped."
                    unless find
                        log.error "Stop failed: application #{app} not found"
                else
                    log.error "Stop failed: no applications installed."


program
    .command("stop-all")
    .description("Stop all user applications")
    .action ->

        stopApps = (app) ->
            (callback) ->
                log.info "\nStop #{app.name}..."
                stopApp app, (err) ->
                    if err
                        log.error "\nStopping #{app.name} failed."
                        log.raw err
                    callback()

        homeClient.host = homeUrl
        homeClient.get "api/applications/", (err, res, apps) ->
            funcs = []
            if apps? and apps.rows?
                for app in apps.rows
                    func = stopApps(app)
                    funcs.push func

                async.series funcs, ->
                    log.info "\nAll apps stopped."
                    log.info "Reset proxy routes"

                    statusClient.host = proxyUrl
                    statusClient.get "routes/reset", (err, res, body) ->
                        if err
                            handleError err, body, "Cannot reset routes."
                        else
                            log.info "Reset proxy succeeded."


program
    .command('autostop-all')
    .description("Put all applications in autostop mode" +
        "(except pfm, emails, feeds, nirc and konnectors)")
    .action ->
        unStoppable = ['pfm', 'emails', 'feeds', 'nirc', 'sync', 'konnectors']
        homeClient.host = homeUrl
        homeClient.get "api/applications/", (err, res, apps) ->
            if apps?.rows?
                for app in apps.rows
                    if not(app.name in unStoppable) and not app.isStoppable
                        app.isStoppable = true
                        homeClient.put "api/applications/byid/#{app.id}",
                            app, (err, res) ->
                               log.error app.name
                               log.raw err

# Restart

program
    .command("restart <app>")
    .description("Restart application")
    .action (app) ->
        log.info "Stopping #{app}..."
        if app in ['data-system', 'home', 'proxy']
            client.stop app, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Stop failed."
                else
                    log.info "#{app} successfully stopped."
                    log.info "Starting #{app}..."
                    manifest.name = app
                    manifest.repository.url =
                        "https://github.com/cozy/cozy-#{app}.git"
                    manifest.user = app
                    client.start manifest, (err, res, body) ->
                        if err
                            handleError err, body, "Start failed for #{app}"
                        else
                            log.info "#{app} sucessfully started."
        else
            stopApp slug: app, (err) ->
                if err
                    handleError err, null, "Stop failed"
                else
                    log.info "#{app} successfully stopped"
                    log.info "Starting #{app}..."
                    startApp slug: app, (err) ->
                        if err
                            handleError err, null, "Start failed for #{app}."
                        else
                            log.info "#{app} was sucessfully started."


program
    .command("restart-cozy-stack")
    .description("Restart cozy trough controller")
    .action () ->
        restartApp = (name, callback) ->
            manifest.repository.url =
                    "https://github.com/cozy/cozy-#{name}.git"
            manifest.name = name
            manifest.user = name
            log.info "Restart started for #{name}..."
            client.stop name, (err, res, body) ->
                client.start manifest, (err, res, body)  ->
                    if err or body.error?
                        handleError err, body, "Start failed for #{name}."
                    else
                        log.info "#{name} was successfully started."
                        callback null

        restartApp 'data-system', () =>
            restartApp 'home', () =>
                restartApp 'proxy', () =>
                    log.info 'Cozy stack successfully restarted.'


# Update

program
    .command("update <app> [repo]")
    .description(
        "Update application (git + npm) and restart it. Option repo " +
        "is usefull only if app comes from a specific repo")
    .action (app, repo) ->

        log.info "Updating #{app}..."
        if app in ['data-system', 'home', 'proxy']
            manifest.name = app
            if repo?
                manifest.repository.url = repo
            else
                manifest.repository.url =
                    "https ://github.com/cozy/cozy-#{app}.git"
            manifest.user = app
            client.lightUpdate manifest, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Update failed."
                else
                    log.info "#{app} was successfully updated."
        else
            find = false
            homeClient.get "api/applications/", (err, res, apps) ->
                if apps? and apps.rows?
                    for manifest in apps.rows
                        if manifest.name is app
                            find = true
                            path = "api/applications/#{manifest.slug}/update"
                            homeClient.put path, manifest, (err, res, body) ->
                                if err or body.error
                                    handleError err, body, "Update failed."
                                else
                                    log.info "#{app} was successfully updated"
                    if not find
                        log.error "Update failed: #{app} was not found."
                else
                    log.error "Update failed: no application installed"


program
    .command("update-cozy-stack")
    .description(
        "Update application (git + npm) and restart it through controller")
    .action () ->
        updateApp = (name, callback) ->
            manifest.repository.url =
                    "https://github.com/cozy/cozy-#{name}.git"
            manifest.name = name
            manifest.user = name

            log.info "Light update #{name}..."
            client.lightUpdate manifest, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Light update failed."
                else
                    log.info "#{name} was successfully updated."
                    callback null

        updateApp 'data-system', () =>
            updateApp 'home', () =>
                updateApp 'proxy', () =>
                    log.info 'Cozy stack successfully updated'

program
    .command("update-all-cozy-stack [token]")
    .description(
        "Update all cozy stack application (DS + proxy + home + controller)")
    .action (token) ->

        updateController = (callback) ->
            log.info "Update controller ..."
            exec "npm -g update cozy-controller", (err, stdout) ->
                if err
                    handleError err, null, "Light update failed."
                else
                    log.info "Controller was successfully updated."
                    callback null

        restartController = (callback) ->
            log.info "Restart controller ..."
            exec "supervisorctl restart cozy-controller", (err, stdout) ->
                if err
                    handleError err, null, "Light update failed."
                else
                    log.info "Controller was successfully restarted."
                    callback null

        updateApp = (name, callback) ->
            manifest.repository.url =
                    "https://github.com/cozy/cozy-#{name}.git"
            manifest.name = name
            manifest.user = name

            log.info "Update #{name}..."
            client.lightUpdate manifest, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Light update failed."
                else
                    log.info "#{name} was successfully updated."
                    callback null

        if token
            client = new ControllerClient
                token: token

        updateController ->
            updateApp 'data-system', ->
                updateApp 'home', ->
                    updateApp 'proxy', ->
                        restartController ->
                            log.info 'Cozy stack successfully updated'


program
    .command("update-all")
    .description("Reinstall all user applications")
    .action ->

        lightUpdateApp = (app, callback) ->
            path = "api/applications/#{app.slug}/update"
            homeClient.put path, app, (err, res, body) ->
                if err
                    callback err
                else if body.error
                    callback body.error
                else
                    callback()

        endUpdate = (app, callback) ->
            path = "api/applications/byid/#{app.id}"
            homeClient.get path, (err, res, app) ->
                if app.state is "installed"
                    log.info " * New status: " + "started".bold
                else
                    if app?.state?
                        log.info " * New status: " + app.state.bold
                    else
                        log.info " * New status: unknown"
                log.info "#{app.name} updated"
                callback()

        updateApp = (app) ->
            (callback) ->
                log.info "\nStarting update #{app.name}..."
                # When application is broken, try :
                #   * remove application
                #   * install application
                #   * stop application
                switch app.state
                    when 'broken'
                        log.info " * Old status: " + "broken".bold
                        log.info " * Remove #{app.name}"
                        removeApp app, (err, body) ->
                            if err
                                log.error 'An error occured: '
                                log.raw err
                                log.raw body

                            log.info " * Install #{app.name}"
                            installApp app, (err) ->
                                if err
                                    log.error 'An error occured:'
                                    log.raw err
                                    endUpdate app, callback
                                else

                                    log.info " * Stop #{app.name}"
                                    stopApp app, (err) ->
                                        if err
                                            log.error 'An error occured:'
                                            log.raw err
                                        endUpdate app, callback

                    # When application is installed, try :
                    #   * update application
                    when 'installed'
                        log.info " * Old status: " + "started".bold
                        log.info " * Update #{app.name}"
                        lightUpdateApp app, (err) ->
                            if err
                                log.error 'An error occured:'
                                log.raw err
                            endUpdate app, callback

                    # When application is stopped, try :
                    #   * update application
                    else
                        log.info " * Old status: " + "stopped".bold
                        log.info " * Update #{app.name}"
                        lightUpdateApp app, (err) ->
                            if err
                                log.error 'An error occured:'
                                log.raw err
                            endUpdate app, callback

        homeClient.host = homeUrl
        homeClient.get "api/applications/", (err, res, apps) ->
            funcs = []
            if apps? and apps.rows?
                for app in apps.rows
                    func = updateApp app
                    funcs.push func

                async.series funcs, ->
                    log.info "\nAll apps reinstalled."
                    log.info "Reset proxy routes"

                    statusClient.host = proxyUrl
                    statusClient.get "routes/reset", (err, res, body) ->
                        if err
                            handleError err, body, "Cannot reset proxy routes."
                        else
                            log.info "Resetting proxy routes succeeded."


# Versions


program
    .command("versions-stack")
    .description("Display stack applications versions")
    .action () ->
        log.raw ''
        log.raw 'Cozy Stack:'.bold
        getVersion "controller"
        getVersion "data-system"
        getVersion "home"
        getVersion 'proxy'
        getVersionIndexer (indexerVersion) =>
            log.raw "indexer: #{indexerVersion}"
            log.raw "monitor: #{version}"


program
    .command("versions")
    .description("Display applications versions")
    .action () ->
        log.raw ''
        log.raw 'Cozy Stack:'.bold
        getVersion "controller"
        getVersion "data-system"
        getVersion "home"
        getVersion 'proxy'
        getVersionIndexer (indexerVersion) =>
            log.raw "indexer: #{indexerVersion}"
            log.raw "monitor: #{version}"
            log.raw ''
            log.raw "Other applications: ".bold
            homeClient.host = homeUrl
            homeClient.get "api/applications/", (err, res, apps) ->
                if apps?.rows?
                    log.raw "#{app.name}: #{app.version}" for app in apps.rows


## Monitoring ###


program
    .command("dev-route:start <slug> <port>")
    .description("Create a route so we can access it by the proxy. ")
    .action (slug, port) ->
        client = request.newClient dataSystemUrl
        client.setBasicAuth 'home', token if token = getToken()

        packagePath = process.cwd() + '/package.json'
        try
            packageData = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
        catch err
            log.error "Run this command in the package.json directory"
            log.raw err
            return

        perms = {}
        for doctype, perm of packageData['cozy-permissions']
            perms[doctype.toLowerCase()] = perm

        data =
            docType: "Application"
            state: 'installed'
            isStoppable: false
            slug: slug
            name: slug
            password: slug
            permissions: perms
            widget: packageData['cozy-widget']
            port: port
            devRoute: true

        client.post "data/", data, (err, res, body) ->
            if err
                handleError err, body, "Create route failed"
            else
                statusClient.host = proxyUrl
                statusClient.get "routes/reset", (err, res, body) ->
                    if err
                        handleError err, body, "Reset routes failed"
                    else
                        log.info "Route was successfully created."
                        log.info "Start your app with the following ENV vars:"
                        log.info "NAME=#{slug} TOKEN=#{slug} PORT=#{port}"
                        log.info "Use dev-route:stop #{slug} to remove it."


program
    .command("dev-route:stop <slug>")
    .action (slug) ->
        client = request.newClient dataSystemUrl
        client.setBasicAuth 'home', token if token = getToken()
        appsQuery = 'request/application/all/'

        stopRoute = (app) ->
            isSlug = (app.key is slug or slug is 'all')
            if isSlug and app.value.devRoute
                client.del "data/#{app.id}/", (err, res, body) ->
                    if err
                        handleError err, body, "Unable to delete route."
                    else
                        log.info "Route deleted."
                        client.host = proxyUrl
                        client.get 'routes/reset', (err, res, body) ->
                            if err
                                msg = "Stop reseting proxy routes."
                                handleError err, body, msg
                            else
                                log.info "Reseting proxy routes succeeded."


        client.post appsQuery, null, (err, res, apps) ->
            if err or not apps?
                handleError err, apps, "Unable to retrieve apps data."
            else
                apps.forEach stopRoute
            console.log "There is no dev route with this slug"


program
    .command("routes")
    .description("Display routes currently configured inside proxy.")
    .action ->
        log.info "Display proxy routes..."

        statusClient.host = proxyUrl
        statusClient.get "routes", (err, res, routes) ->

            if err
                handleError err, {}, "Cannot display routes."
            else if routes?
                for route of routes
                    log.raw "#{route} => #{routes[route].port}"


program
    .command("module-status <module>")
    .description("Give status of given in an easy to parse way.")
    .action (module) ->
        urls =
            controller: controllerUrl
            "data-system": dataSystemUrl
            indexer: indexerUrl
            home: homeUrl
            proxy: proxyUrl
        statusClient.host = urls[module]
        statusClient.get '', (err, res) ->
            if not res? or not res.statusCode in [200, 401, 403]
                console.log "down"
            else
                console.log "up"


program
    .command("status")
    .description("Give current state of cozy platform applications")
    .action ->
        checkApp = (app, host, path="") ->
            (callback) ->
                statusClient.host = host
                statusClient.get path, (err, res) ->
                    if (res? and not res.statusCode in [200,403]) or (err? and
                        err.code is 'ECONNREFUSED')
                            log.raw "#{app}: " + "down".red
                    else
                        log.raw "#{app}: " + "up".green
                    callback()
                , false

        async.series [
            checkApp "postfix", postfixUrl
            checkApp "couchdb", couchUrl
            checkApp "controller", controllerUrl, "version"
            checkApp "data-system", dataSystemUrl
            checkApp "home", homeUrl
            checkApp "proxy", proxyUrl, "routes"
            checkApp "indexer", indexerUrl
        ], ->
            statusClient.host = homeUrl
            statusClient.get "api/applications/", (err, res, apps) ->
                funcs = []
                if apps? and apps.rows?
                    for app in apps.rows
                        if app.state is 'stopped'
                            log.raw "#{app.name}: " + "stopped".grey
                        else
                            url = "http://localhost:#{app.port}/"
                            func = checkApp app.name, url
                            funcs.push func
                    async.series funcs, ->


program
    .command("log <app> <type>")
    .description("Display application log with cat or tail -f")
    .action (app, type, environment) ->
        path = "/usr/local/var/log/cozy/#{app}.log"

        if not fs.existsSync path
            log.error "Log file doesn't exist (#{path})."

        else if type is "cat"
            log.raw fs.readFileSync path, 'utf8'

        else if type is "tail"
            tail = spawn "tail", ["-f", path]

            tail.stdout.setEncoding 'utf8'
            tail.stdout.on 'data', (data) =>
                log.raw data

            tail.on 'close', (code) =>
                log.info "ps process exited with code #{code}"

        else
            log.info "<type> should be 'cat' or 'tail'"


## Database ##

program
    .command("compact [database]")
    .description("Start couchdb compaction")
    .action (database) ->
        database ?= "cozy"
        configureCouchClient()

        log.info "Start couchdb compaction on #{database} ..."
        couchClient.headers['content-type'] = 'application/json'
        couchClient.post "#{database}/_compact", {}, (err, res, body) ->
            if err or not body.ok
                handleError err, body, "Compaction failed."
            else
                waitCompactComplete couchClient, false, (success) =>
                    log.info "#{database} compaction succeeded"
                    process.exit 0


program
    .command("compact-views <view> [database]")
    .description("Start couchdb compaction")
    .action (view, database) ->
        database ?= "cozy"

        log.info "Start vews compaction on #{database} for #{view} ..."
        compactViews database, view, (err) =>
            if not err
                log.info "#{database} compaction for #{view} succeeded"
                process.exit 0


program
    .command("compact-all-views [database]")
    .description("Start couchdb compaction")
    .action (database) ->
        database ?= "cozy"
        configureCouchClient()

        log.info "Start vews compaction on #{database} ..."
        path = "#{database}/_all_docs?startkey=\"_design/\"&endkey=" +
            "\"_design0\"&include_docs=true"

        couchClient.get path, (err, res, body) =>
            if err
                handleError err, body, "Views compaction failed. " +
                    "Cannot recover all design documents"
            else
                designs = []
                body.rows.forEach (design) ->
                    designId = design.id
                    designDoc = designId.substring 8, designId.length
                    designs.push designDoc

                compactAllViews database, designs, (err) =>
                    if not err
                        log.info "Views are successfully compacted"


program
    .command("cleanup [database]")
    .description("Start couchdb cleanup")
    .action (database) ->
        database ?= "cozy"

        log.info "Start couchdb cleanup on #{database}..."
        configureCouchClient()
        couchClient.post "#{database}/_view_cleanup", {}, (err, res, body) ->
            if err or not body.ok
                handleError err, body, "Cleanup failed."
            else
                log.info "#{database} cleanup succeeded"
                process.exit 0

## Backup ##

program
    .command("backup <target>")
    .description("Start couchdb replication to the target")
    .action (target) ->
        data =
            source: "cozy"
            target: target

        configureCouchClient()
        couchClient.post "_replicate", data, (err, res, body) ->
            if err or not body.og
                handleError err, body, "Backup failed."
            else
                log.info "Backup succeeded"
                process.exit 0


program
    .command("reverse-backup <backup> <username> <password>")
    .description("Start couchdb replication from target to cozy")
    .action (backup, usernameBackup, passwordBackup) ->
        log.info "Reverse backup..."


        [username, password] = getAuthCouchdb()

        prepareCozyDatabase username, password, ->
            toBase64 = (str) ->
                new Buffer(str).toString('base64')

            # Initialize creadentials for backup
            credentials = "#{usernameBackup}:#{passwordBackup}"
            basicCredentials = toBase64 credentials
            authBackup = "Basic #{basicCredentials}"

            # Initialize creadentials for cozy database
            credentials = "#{username}:#{password}"
            basicCredentials = toBase64 credentials
            authCozy = "Basic #{basicCredentials}"

            # Initialize data for replication
            data =
                source:
                    url: backup
                    headers:
                        Authorization: authBackup
                target:
                    url: "#{couchUrl}cozy"
                    headers:
                        Authorization: authCozy

            # Database replication
            couchClient.post "_replicate", data, (err, res, body) ->
                if err or not body.ok
                    handleError err, body, "Backup failed."
                else
                    log.info "Reverse backup succeeded"
                    process.exit 0

## Others ##

program
    .command("reset-proxy")
    .description("Reset proxy routes list of applications given by home.")
    .action ->
        log.info "Reset proxy routes"

        statusClient.host = proxyUrl
        statusClient.get "routes/reset", (err, res, body) ->
            if err
                handleError err, body, "Reset routes failed"
            else
                log.info "Reset proxy succeeded."


program
    .command("*")
    .description("Display error message for an unknown command.")
    .action ->
        log.error 'Unknown command, run "cozy-monitor --help"' + \
                    ' to know the list of available commands.'

program.parse process.argv

unless process.argv.slice(2).length
    program.outputHelp()

