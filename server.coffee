HOST = null # localhost
#PORT = 8003
PORT = 9817

# when the daemon started
starttime = (new Date).getTime()
static_files = ["/", "/style.css", "/client.js", "/jquery-1.2.6.min.js", "/soundmanager2.js", "/swf/soundmanager2.swf", "/swfobject.js", "/media_queue.js"]
###
var mem = process.memoryUsage()
every 10 seconds poll for the memory.
setInterval(function () {
  mem = process.memoryUsage()
}, 10*1000)
###
mem = {rss:'100'}


sys = require("sys")
url = require("url")
qs = require("querystring")
formidable = require("formidable")
http = require("http")
path = require("path")
fs = require("fs")
util = require("util")

MESSAGE_BACKLOG = 200
SESSION_TIMEOUT = 60 * 1000

class Channel
  constructor: ->
    @messages = []
    @callbacks = []
    @files = [".gitignore"]
    # clear old callbacks
    # they can hang around for at most 30 seconds.
    clearCallbacks = =>
      now = new Date
      while @callbacks.length > 0 && now - @callbacks[0].timestamp > 30*1000
        @callbacks.shift().callback []
      
    setInterval clearCallbacks, 3000

  appendMessage: (nick, type, text) ->
    m = { 
          nick: nick, 
          type: type, # "msg", "join", "part"
          text: text,
          timestamp: (new Date).getTime()
        }
    switch type
      when "msg" then sys.puts("<" + nick + "> " + text)
      when "join" then sys.puts(nick + " join")
      when "part" then sys.puts(nick + " part")
      when "upload" then @files.push text
    @messages.push( m )
    while (@callbacks.length > 0)
      @callbacks.shift().callback([m])
    while (@messages.length > MESSAGE_BACKLOG)
      @messages.shift()

  query: (since, callback) ->
    matching = []
    for message in @messages
      if (message.timestamp > since)
        matching.push(message)
    if matching.length != 0
      callback matching
    else
      @callbacks.push { timestamp: new Date, callback: callback }

channel = new Channel
sessions = {}

createSession = (nick) ->
  if nick.length > 50 
    return null
  if (/[^\w_\-^!]/.exec(nick)) 
    return null

  for session in sessions
    if (session && session.nick == nick) 
      return null

  session = { 
    nick: nick, 
    id: Math.floor(Math.random()*99999999999).toString(),
    timestamp: new Date,

    poke: ->
      session.timestamp = new Date

    destroy: ->
      channel.appendMessage(session.nick, "part")
      delete sessions[session.id]
  }

  sessions[session.id] = session;
  session
  
# interval to kill off old sessions
setInterval () ->
  now = new Date
  for session in sessions
    if (now - session.timestamp > SESSION_TIMEOUT)
      session.destroy()
, 1000

http.createServer (req, res) ->
  pathname = url.parse(req.url).pathname
  
  res.simpleJSON = (code, obj) ->
    body = new Buffer(JSON.stringify(obj))
    res.writeHead(code, { "Content-Type": "text/json", "Content-Length": body.length})
    res.end(body)
  
  if req.url == '/upload' && req.method.toLowerCase() == 'post'
    # parse a file upload
    form = new formidable.IncomingForm()
    form.parse req, (err, fields, files) ->
      res.writeHead(200, {'content-type': 'text/html'})
      result = '''
        <h2>Upload a Song (mp3)</h2>
        <form action="/upload" enctype="multipart/form-data" method="post">
        <input type="text" name="title" style="float:left">
        <input type="file" name="upload" multiple="multiple" style="float:left">
        <input type="submit" value="Upload" style="float:left">
        </form>
      '''
      res.end result 
      if files.upload && files.upload.name.match(/mp3/i)
        sys.puts("file upload " + files.upload.name)
        fs.rename(files.upload.path, 'tmp/' + files.upload.name)
        channel.appendMessage(null, "upload", files.upload.name)
    return

  else if (req.url == '/form')
    # show a file upload form
    res.writeHead(200, {'content-type': 'text/html'})
    result = '<h2>Upload a Song (mp3)</h2>
      <form action="/upload" enctype="multipart/form-data" method="post">
      <input type="text" name="title" style="float:left">
      <input type="file" name="upload" multiple="multiple" style="float:left">
      <input type="submit" value="Upload" style="float:left">
      </form>'
    res.end result
    
  else if req.url == '/submit_youtube_link' && req.method.toLowerCase() == 'post'
    form = new formidable.IncomingForm()
    form.parse req, (err, fields, files) ->
      match = fields.youtube_link.match /// ^ (
        http://www.youtube.com/watch\?v=([^&]*)
      ) ///
      if match
        sys.puts "submitted youtube link #{match[2]}"
        channel.appendMessage(null, "youtube", match[2])
      res.end "ok"
    
  else if (pathname == "/send")
    id = qs.parse(url.parse(req.url).query).id
    text = qs.parse(url.parse(req.url).query).text
    session = sessions[id]
    if (!session || !text)
      res.simpleJSON(400, { error: "No such session id" })
      return
    session.poke()
    channel.appendMessage(session.nick, "msg", text)
    res.simpleJSON(200, { rss: mem.rss })

  else if req.url == '/cleanup_bad_files'
    fs.readdir './tmp', (err, files) ->
      for file in files
        if !file.match(/^.gitignore$|\.mp3$/)
          fs.unlink './tmp/' + file
      res.writeHead(200, {'content-type': 'text/html'})
      res.end "OK"
    
  else if req.url.match(/^\/files/)
    fs.readdir './tmp', (err, files) ->
      files.splice(files.indexOf(".gitignore"), 1)
      res.writeHead(200, {'content-type': 'text/html'})
      res.end(new Buffer(JSON.stringify({files: files})))
  
  else if req.url == "/submit_file"
    form = new formidable.IncomingForm()
    form.parse req, (err, fields, files) ->
      channel.appendMessage(null, "upload", fields.song_selection)
      res.writeHead(200, {'content-type': 'text/html'})
      res.end "OK"
  
  else if pathname == "/recv"
    if !qs.parse(url.parse(req.url).query).since
      res.simpleJSON(400, { error: "Must supply since parameter" })
      return
    id = qs.parse(url.parse(req.url).query).id
    if id && sessions[id]
      session = sessions[id]
      session.poke()
    since = parseInt qs.parse(url.parse(req.url).query).since, 10
    channel.query since, (messages) ->
      if (session) 
        session.poke()
      res.simpleJSON(200, { messages: messages, rss: mem.rss })
  
  else if (pathname == "/part")
    id = qs.parse(url.parse(req.url).query).id
    if (id && sessions[id])
      session = sessions[id]
      session.destroy()
    res.simpleJSON(200, { rss: mem.rss })
  
  else if (pathname == "/join")
    nick = qs.parse(url.parse(req.url).query).nick
    if (nick == null || nick.length == 0)
      res.simpleJSON(400, {error: "Bad nick."})
      return
    session = createSession(nick)
    if session == null
      res.simpleJSON(400, {error: "Nick in use"})
      return
    channel.appendMessage(session.nick, "join")
    response_json = { id: session.id, nick: session.nick, rss: mem.rss, starttime: starttime }
    res.simpleJSON(200, response_json)
  
  else if pathname == "/who"
    nicks = []
    for session in sessions
      if (!sessions.hasOwnProperty(id)) 
        continue
      session = sessions[id]
      nicks.push(session.nick)
    res.simpleJSON(200, { nicks: nicks, rss: mem.rss})
  
  else if match = pathname.match(/\/tmp\/(.*)/)
    filename = match[1]
    fs.readFile "tmp/" + qs.unescape(filename), "binary", (err, file) ->
      if(err)
        console.log(err)
        res.writeHead(404, {"Content-Type": "text/plain"})  
        res.write(err + "\n")  
        res.end()  
        return  
      res.writeHead(200)  
      res.write(file, "binary")  
      res.end()  
  
  else if (req.url in static_files)
    uri = url.parse(req.url).pathname  
    filename = path.join(process.cwd(), uri)
    if (req.url == "/")
      filename = "index.html"
    fs.readFile filename, "binary", (err, file) ->
      if(err)
        res.writeHead(500, {"Content-Type": "text/plain"})  
        res.write(err + "\n")  
        res.close()  
        return  
      res.writeHead(200)  
      res.write(file, "binary")  
      res.end()
  
  else
    res.writeHead(404, {"Content-Type": "text/plain"})  
    res.write("bad request" + req.url)  
    sys.puts("bad request" + req.url)
    res.end()
.listen(Number(process.env.PORT || PORT), HOST)

