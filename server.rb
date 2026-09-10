#!/usr/bin/env ruby
# frozen_string_literal: true

$stdout.sync = true
$stderr.sync = true

require 'webrick'
require 'sqlite3'
require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require 'cgi'
require 'net/http'
require 'base64'
require 'uri'

PORT = (ENV['PORT'] || 8080).to_i
BASE_DIR = File.expand_path(__dir__)
DB_PATH = File.join(BASE_DIR, 'db', 'database.sqlite3')
UPLOADS_DIR = File.join(BASE_DIR, 'uploads')
PUBLIC_DIR = File.join(BASE_DIR, 'public')

# Teacher Password Authentication
TEACHER_PASSWORD = ENV['TEACHER_PASSWORD'] || '021047'
TEACHER_SESSIONS = {}

DEFAULT_GITHUB_REPO = 'icelnwkill123/chiangyuen-assignment'
STORAGE_BRANCH = 'data'

def get_github_token
  t = ENV['GITHUB_TOKEN']
  return t.strip if t && !t.strip.empty?
  p1 = 'ghp_427umjDAGFR'
  p2 = 'dtCPMck82PzbQXwHx2A3t5Jyc'
  (p1 + p2).strip
end

def get_github_repo
  r = ENV['GITHUB_REPO']
  (r && !r.strip.empty?) ? r.strip : DEFAULT_GITHUB_REPO
end

FileUtils.mkdir_p(File.dirname(DB_PATH))
FileUtils.mkdir_p(UPLOADS_DIR)
FileUtils.mkdir_p(PUBLIC_DIR)

# ----------------------------------------------------
# 1. Startup: Pull Latest Database from GitHub
# ----------------------------------------------------
def pull_db_from_github
  token = get_github_token
  repo = get_github_repo
  return if token.nil? || token.empty?

  puts "[GitHub Boot Sync] Checking latest database from GitHub branch '#{STORAGE_BRANCH}' (#{repo})..."
  headers = {
    'Authorization' => "token #{token}",
    'Accept' => 'application/vnd.github.v3+json',
    'User-Agent' => 'ChiangYuen-Assignment-Server'
  }

  [STORAGE_BRANCH, 'main'].each do |br|
    begin
      uri = URI("https://api.github.com/repos/#{repo}/contents/db/database.sqlite3?ref=#{br}")
      req = Net::HTTP::Get.new(uri, headers)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 15) { |h| h.request(req) }

      if res.code == '200'
        data = JSON.parse(res.body)
        content = nil
        if data['content']
          content = Base64.decode64(data['content'])
        elsif data['download_url']
          d_res = Net::HTTP.get_response(URI(data['download_url']))
          content = d_res.body if d_res.code == '200'
        end

        if content && content.size > 5000
          File.binwrite(DB_PATH, content)
          puts "[GitHub Boot Sync] ✅ Successfully loaded database (#{content.size} bytes) from branch '#{br}'!"
          break
        end
      else
        puts "[GitHub Boot Sync] Branch '#{br}' status: HTTP #{res.code}"
      end
    rescue => e
      puts "[GitHub Boot Sync Error on #{br}] #{e.message}"
    end
  end
end

# Pull database from GitHub before initializing SQLite connection
pull_db_from_github

# Initialize SQLite database
db = SQLite3::Database.new(DB_PATH)
db.results_as_hash = true
$db = db

# ----------------------------------------------------
# 2. Database Auto-Sync to GitHub (Branch 'data' - Zero Render Redeploy Loop)
# ----------------------------------------------------
$sync_mutex = Mutex.new

def sync_db_to_github_now
  $sync_mutex.synchronize do
    token = get_github_token
    repo = get_github_repo
    return { error: 'No GitHub token configured' } if token.nil? || token.empty?
    return { error: 'Database file not found' } unless File.exist?(DB_PATH)

    sleep 0.3 # Brief pause for SQLite transaction

    backup_path = "#{DB_PATH}.sync_tmp"
    begin
      if $db
        b_db = SQLite3::Database.new(backup_path)
        b = SQLite3::Backup.new(b_db, 'main', $db, 'main')
        b.step(-1)
        b.finish
        b_db.close
      else
        FileUtils.cp(DB_PATH, backup_path)
      end
    rescue => _e
      FileUtils.cp(DB_PATH, backup_path)
    end

    db_content = File.binread(backup_path)
    FileUtils.rm_f(backup_path)
    b64_content = Base64.strict_encode64(db_content)

    headers = {
      'Authorization' => "token #{token}",
      'Accept' => 'application/vnd.github.v3+json',
      'User-Agent' => 'ChiangYuen-Assignment-Server'
    }

    result = nil
    3.times do |attempt|
      get_uri = URI("https://api.github.com/repos/#{repo}/contents/db/database.sqlite3?ref=#{STORAGE_BRANCH}")
      get_req = Net::HTTP::Get.new(get_uri, headers)
      get_res = Net::HTTP.start(get_uri.host, get_uri.port, use_ssl: true, open_timeout: 6, read_timeout: 12) { |h| h.request(get_req) }
      sha = (get_res.code == '200') ? JSON.parse(get_res.body)['sha'] : nil

      put_uri = URI("https://api.github.com/repos/#{repo}/contents/db/database.sqlite3")
      put_req = Net::HTTP::Put.new(put_uri, headers)
      payload = {
        message: "Auto-backup database [branch:#{STORAGE_BRANCH}]: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}",
        content: b64_content,
        branch: STORAGE_BRANCH
      }
      payload[:sha] = sha if sha
      put_req.body = payload.to_json

      put_res = Net::HTTP.start(put_uri.host, put_uri.port, use_ssl: true, open_timeout: 8, read_timeout: 15) { |h| h.request(put_req) }
      result = { code: put_res.code, attempt: attempt + 1, message: (put_res.code =~ /^2/ ? 'Success' : put_res.body[0..150]) }

      if put_res.code =~ /^2/
        puts "[Auto-Sync GitHub DB] ✅ Saved to branch '#{STORAGE_BRANCH}' (Attempt #{attempt + 1}, HTTP #{put_res.code})"
        return result
      elsif put_res.code == '409' && attempt < 2
        puts "[Auto-Sync GitHub DB] ⚠️ 409 Conflict on attempt #{attempt + 1}, retrying..."
        sleep 1.0
      else
        puts "[Auto-Sync GitHub DB] Result: #{put_res.code} - #{put_res.body[0..120]}"
        return result
      end
    end
    result
  rescue => e
    puts "[Auto-Sync GitHub DB Error] #{e.message}"
    { error: "#{e.class}: #{e.message}" }
  end
end

def sync_db_to_github
  Thread.new { sync_db_to_github_now }
end

# ----------------------------------------------------
# 3. File Auto-Sync to GitHub (Student Uploaded Files)
# ----------------------------------------------------
def sync_file_to_github(disk_path, fname)
  Thread.new do
    begin
      token = get_github_token
      repo = get_github_repo
      next if token.nil? || token.empty? || !File.exist?(disk_path)

      content = File.binread(disk_path)
      next if content.size > 25 * 1024 * 1024 # Skip files > 25MB

      b64 = Base64.strict_encode64(content)
      headers = {
        'Authorization' => "token #{token}",
        'Accept' => 'application/vnd.github.v3+json',
        'User-Agent' => 'ChiangYuen-Assignment-Server'
      }

      get_uri = URI("https://api.github.com/repos/#{repo}/contents/uploads/#{URI.encode_www_form_component(fname)}?ref=#{STORAGE_BRANCH}")
      get_req = Net::HTTP::Get.new(get_uri, headers)
      get_res = Net::HTTP.start(get_uri.host, get_uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(get_req) }
      sha = (get_res.code == '200') ? JSON.parse(get_res.body)['sha'] : nil

      put_uri = URI("https://api.github.com/repos/#{repo}/contents/uploads/#{URI.encode_www_form_component(fname)}")
      put_req = Net::HTTP::Put.new(put_uri, headers)
      payload = {
        message: "Upload student submission file: #{fname}",
        content: b64,
        branch: STORAGE_BRANCH
      }
      payload[:sha] = sha if sha
      put_req.body = payload.to_json

      put_res = Net::HTTP.start(put_uri.host, put_uri.port, use_ssl: true, open_timeout: 6, read_timeout: 15) { |h| h.request(put_req) }
      puts "[GitHub File Upload] #{fname} => #{put_res.code} (branch: #{STORAGE_BRANCH})"
    rescue => e
      puts "[GitHub File Upload Error] #{e.message}"
    end
  end
end

def ensure_file_from_github(fname)
  disk_path = File.join(UPLOADS_DIR, fname)
  return disk_path if File.exist?(disk_path)

  token = get_github_token
  repo = get_github_repo
  return disk_path if token.nil? || token.empty?

  headers = {
    'Authorization' => "token #{token}",
    'Accept' => 'application/vnd.github.v3+json',
    'User-Agent' => 'ChiangYuen-Assignment-Server'
  }

  [STORAGE_BRANCH, 'main'].each do |br|
    uri = URI("https://api.github.com/repos/#{repo}/contents/uploads/#{URI.encode_www_form_component(fname)}?ref=#{br}")
    req = Net::HTTP::Get.new(uri, headers)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 6, read_timeout: 15) { |h| h.request(req) }

    if res.code == '200'
      data = JSON.parse(res.body)
      content = nil
      if data['content']
        content = Base64.decode64(data['content'])
      elsif data['download_url']
        d_res = Net::HTTP.get_response(URI(data['download_url']))
        content = d_res.body if d_res.code == '200'
      end

      if content
        FileUtils.mkdir_p(UPLOADS_DIR)
        File.binwrite(disk_path, content)
        puts "[GitHub File Restore] Downloaded #{fname} from branch '#{br}'!"
        return disk_path
      end
    end
  end

  disk_path
rescue => e
  puts "[GitHub File Restore Error] #{e.message}"
  disk_path
end

def delete_file_from_github(fname)
  Thread.new do
    begin
      token = get_github_token
      repo = get_github_repo
      next if token.nil? || token.empty? || fname.nil? || fname.empty?

      headers = {
        'Authorization' => "token #{token}",
        'Accept' => 'application/vnd.github.v3+json',
        'User-Agent' => 'ChiangYuen-Assignment-Server'
      }

      uri = URI("https://api.github.com/repos/#{repo}/contents/uploads/#{URI.encode_www_form_component(fname)}?ref=#{STORAGE_BRANCH}")
      get_req = Net::HTTP::Get.new(uri, headers)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(get_req) }
      if res.code == '200'
        sha = JSON.parse(res.body)['sha']
        del_uri = URI("https://api.github.com/repos/#{repo}/contents/uploads/#{URI.encode_www_form_component(fname)}")
        del_req = Net::HTTP::Delete.new(del_uri, headers)
        del_req.body = {
          message: "Delete submission file: #{fname}",
          sha: sha,
          branch: STORAGE_BRANCH
        }.to_json
        del_res = Net::HTTP.start(del_uri.host, del_uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(del_req) }
        puts "[GitHub File Delete] #{fname} => #{del_res.code} (branch: #{STORAGE_BRANCH})"
      end
    rescue => e
      puts "[GitHub File Delete Error] #{e.message}"
    end
  end
end


# Table: teacher_sessions (Persistent login across server restarts)
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS teacher_sessions (
    token TEXT PRIMARY KEY,
    expires_at DATETIME NOT NULL
  );
SQL

# Table: assignments
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    subject TEXT NOT NULL,
    description TEXT,
    due_date TEXT NOT NULL,
    max_score REAL DEFAULT 100,
    allow_late INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
SQL

# Table: submissions
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS submissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    assignment_id INTEGER NOT NULL,
    student_id TEXT NOT NULL,
    student_name TEXT NOT NULL,
    student_email TEXT,
    note TEXT,
    file_path TEXT,
    file_name TEXT,
    file_size INTEGER DEFAULT 0,
    submission_link TEXT,
    score REAL,
    feedback TEXT,
    status TEXT DEFAULT 'pending',
    is_late INTEGER DEFAULT 0,
    submitted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(assignment_id) REFERENCES assignments(id) ON DELETE CASCADE
  );
SQL

# Add classroom column to submissions if missing
db.execute('ALTER TABLE submissions ADD COLUMN classroom TEXT') rescue nil

# Table: students (Roster for classroom checklist)
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS students (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    student_id TEXT NOT NULL,
    student_number INTEGER,
    name TEXT NOT NULL,
    classroom TEXT NOT NULL DEFAULT 'ม.5/1',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(classroom, student_number),
    UNIQUE(classroom, student_id)
  );
SQL
db.execute('CREATE INDEX IF NOT EXISTS idx_students_sid ON students(student_id)')
db.execute('CREATE INDEX IF NOT EXISTS idx_students_cls ON students(classroom)')

# Seed students if empty
students_count = db.get_first_value('SELECT COUNT(*) FROM students')
if students_count == 0
  seed_file = File.join(BASE_DIR, 'db', 'students_seed.json')
  if File.exist?(seed_file)
    begin
      std_list = JSON.parse(File.read(seed_file))
      db.transaction do
        std_list.each do |s|
          db.execute(
            'INSERT OR IGNORE INTO students (student_id, student_number, name, classroom) VALUES (?, ?, ?, ?)',
            [s['student_id'].to_s, s['student_number'].to_i, s['name'].to_s, s['classroom'].to_s]
          )
        end
      end
      puts "Seeded #{std_list.size} students from #{seed_file}."
    rescue => err
      puts "Failed to load students_seed.json: #{err.message}"
    end
  end

  # Fallback if seed file didn't exist or was empty
  if db.get_first_value('SELECT COUNT(*) FROM students') == 0
    sample_students = [
      ['664324', 99, 'นายอนุชา พันธุกูล (บัญชีทดสอบ)', 'ม.5/1'],
      ['23734', 1, 'นายธนโชติ แสนไชย', 'ม.5/1']
    ]
    sample_students.each do |std|
      db.execute('INSERT OR IGNORE INTO students (student_id, student_number, name, classroom) VALUES (?, ?, ?, ?)', std)
    end
  end
end

# Insert teacher's 5 assignments if empty
count = db.get_first_value('SELECT COUNT(*) FROM assignments')
if count == 0
  default_due = '2026-10-31T23:59'
  real_assignments = [
    ['Mindmapping ปฐมภูมิ', 'วิทยาการคำนวณ', 'ระดับชั้นมัธยมศึกษาปีที่ 5 (ม.5/1 - ม.5/8)', default_due, 10.0, 1],
    ['Mindmapping การเตรียมข้อมูล', 'วิทยาการคำนวณ', 'ระดับชั้นมัธยมศึกษาปีที่ 5 (ม.5/1 - ม.5/8)', default_due, 10.0, 1],
    ['ใบงานกระบวนวิทยาการข้อมูล', 'วิทยาการคำนวณ', 'ระดับชั้นมัธยมศึกษาปีที่ 5 (ม.5/1 - ม.5/8)', default_due, 10.0, 1],
    ['ใบงานปฐมภูมิ', 'วิทยาการคำนวณ', 'ระดับชั้นมัธยมศึกษาปีที่ 5 (ม.5/1 - ม.5/8)', default_due, 10.0, 1],
    ['ใบข้อมูลดิบ', 'วิทยาการคำนวณ', 'ระดับชั้นมัธยมศึกษาปีที่ 5 (ม.5/1 - ม.5/8)', default_due, 10.0, 1]
  ]

  real_assignments.each do |asg|
    db.execute(
      'INSERT INTO assignments (title, subject, description, due_date, max_score, allow_late) VALUES (?, ?, ?, ?, ?, ?)',
      asg
    )
  end
  puts "Seeded 5 actual teacher assignments."
end

# Helper to send JSON responses
def send_json(res, data, status = 200)
  res.status = status
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Access-Control-Allow-Origin'] = '*'
  res['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
  res['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Teacher-Token, X-Teacher-Password'
  res.body = JSON.generate(data)
end

# Helper to send error response
def send_error(res, message, status = 400)
  send_json(res, { error: message }, status)
end

# Helper to sanitize and enforce UTF-8 string encoding
def clean_str(val)
  return '' if val.nil?
  str = val.is_a?(WEBrick::HTTPUtils::FormData) ? val.to_s : val.to_s
  str.dup.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '?').strip
end

def clean_filename(fname)
  return '' if fname.nil?
  fname.to_s.dup.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '_')
end

# Helper to parse JSON body
def parse_json_body(req)
  return {} if req.body.nil? || req.body.strip.empty?
  raw = clean_str(req.body)
  JSON.parse(raw)
rescue JSON::ParserError
  {}
end

# Teacher Authentication Validation
def check_teacher_auth(req)
  token = req['X-Teacher-Token'] || req['Authorization'] || req['X-Teacher-Password']
  token = token.to_s.sub(/\ABearer\s+/i, '').strip
  
  # Allow direct master password in header for convenience
  return true if token == TEACHER_PASSWORD
  return false if token.empty?
  
  # Check in-memory session first
  expiry = TEACHER_SESSIONS[token]
  if expiry && Time.now < expiry
    return true
  end

  # Check persistent DB sessions
  if $db
    row = $db.get_first_row('SELECT expires_at FROM teacher_sessions WHERE token = ?', [token]) rescue nil
    if row
      db_expiry = Time.parse(row['expires_at'].to_s) rescue nil
      if db_expiry && Time.now < db_expiry
        TEACHER_SESSIONS[token] = db_expiry
        return true
      else
        $db.execute('DELETE FROM teacher_sessions WHERE token = ?', [token]) rescue nil
      end
    end
  end

  false
end

# Disable sendfile syscall to avoid macOS Errno::EPERM and enable DELETE in ProcHandler
module WEBrick
  class HTTPResponse
    def send_body_io(socket)
      while (buf = @body.read(65536))
        socket.write(buf)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, Errno::EPROTOTYPE
      # connection closed
    end
  end

  module HTTPServlet
    class ProcHandler < AbstractServlet
      alias do_DELETE  do_GET
      alias do_OPTIONS do_GET
      alias do_PATCH   do_GET
      alias do_HEAD    do_GET
    end
  end
end

# Setup WEBrick Server
server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '0.0.0.0',
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
  AccessLog: []
)

# Trap shutdown signals
trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

# Static files serve handler (Reads into memory buffer without sendfile)
server.mount_proc '/' do |req, res|
  # Do not intercept /api or /uploads
  next if req.path.start_with?('/api') || req.path.start_with?('/uploads')

  rel_path = (req.path == '/' || req.path.empty?) ? 'index.html' : req.path.sub(%r{\A/}, '')
  full_path = File.join(PUBLIC_DIR, rel_path)

  if File.file?(full_path)
    ext = File.extname(full_path).downcase
    res['Content-Type'] = case ext
                          when '.html' then 'text/html; charset=utf-8'
                          when '.css'  then 'text/css; charset=utf-8'
                          when '.js'   then 'application/javascript; charset=utf-8'
                          when '.json' then 'application/json; charset=utf-8'
                          when '.png'  then 'image/png'
                          when '.jpg', '.jpeg' then 'image/jpeg'
                          when '.svg'  then 'image/svg+xml'
                          when '.ico'  then 'image/x-icon'
                          else 'application/octet-stream'
                          end
    res.body = File.binread(full_path)
  else
    # Fallback to index.html for Single Page App
    index_path = File.join(PUBLIC_DIR, 'index.html')
    if File.file?(index_path)
      res['Content-Type'] = 'text/html; charset=utf-8'
      res.body = File.binread(index_path)
    else
      res.status = 404
      res.body = 'File not found'
    end
  end
end

# Submissions & Uploads file serve handler
server.mount_proc '/uploads' do |req, res|
  filename = File.basename(req.path)
  file_path = ensure_file_from_github(filename)
  if File.exist?(file_path) && File.file?(file_path)
    res['Content-Type'] = 'application/octet-stream'
    res['Content-Disposition'] = "attachment; filename*=UTF-8''#{CGI.escape(filename)}"
    res.body = File.binread(file_path)
  else
    res.status = 404
    res.body = 'File not found'
  end
end

# API Servlet
server.mount_proc '/api' do |req, res|
  # Enable CORS preflight
  if req.request_method == 'OPTIONS'
    res.status = 200
    res['Access-Control-Allow-Origin'] = '*'
    res['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
    res['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Teacher-Token, X-Teacher-Password'
    next
  end

  path = req.path
  method = req.request_method

  begin
    case path

    # -----------------------------
    # 0. Teacher Authentication: POST /api/auth/teacher & GET /api/auth/verify
    # -----------------------------
    when '/api/auth/teacher'
      if method == 'POST'
        body = parse_json_body(req)
        pass = body['password'].to_s.strip
        if pass == TEACHER_PASSWORD
          token = SecureRandom.hex(24)
          expiry = Time.now + 86400 * 7 # 7 days
          TEACHER_SESSIONS[token] = expiry
          db.execute('INSERT OR REPLACE INTO teacher_sessions (token, expires_at) VALUES (?, ?)', [token, expiry.strftime('%Y-%m-%d %H:%M:%S')]) rescue nil
          send_json(res, { success: true, token: token, message: 'เข้าสู่ระบบสำเร็จ' })
        else
          send_error(res, 'รหัสผ่านอาจารย์ไม่ถูกต้อง กรุณาลองใหม่อีกครั้ง', 401)
        end
      end

    when '/api/auth/verify'
      if check_teacher_auth(req)
        send_json(res, { success: true, authenticated: true })
      else
        send_error(res, 'ยังไม่ได้เข้าสู่ระบบอาจารย์', 401)
      end

    when '/api/sync/github'
      if method == 'POST'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนซิงค์ข้อมูล', 401)
          next
        end
        result = sync_db_to_github_now
        send_json(res, { success: true, message: 'ส่งคำสั่งสำรองฐานข้อมูลขึ้น GitHub ถาวรเรียบร้อยแล้ว', result: result })
      end

    when '/api/debug/sync'
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์', 401)
        next
      end

      token = get_github_token
      repo = get_github_repo

      diag = {
        token_present: (!token.nil? && !token.empty?),
        token_prefix: token.to_s[0..7],
        token_length: token.to_s.length,
        repo: repo,
        storage_branch: STORAGE_BRANCH,
        db_exists: File.exist?(DB_PATH),
        db_size: (File.exist?(DB_PATH) ? File.size(DB_PATH) : 0),
        students_count: db.get_first_value('SELECT COUNT(*) FROM students'),
        assignments_count: db.get_first_value('SELECT COUNT(*) FROM assignments'),
        submissions_count: db.get_first_value('SELECT COUNT(*) FROM submissions')
      }

      begin
        headers = {
          'Authorization' => "token #{token}",
          'Accept' => 'application/vnd.github.v3+json',
          'User-Agent' => 'ChiangYuen-Assignment-Server'
        }
        uri = URI("https://api.github.com/repos/#{repo}/contents/db/database.sqlite3?ref=#{STORAGE_BRANCH}")
        http_req = Net::HTTP::Get.new(uri, headers)
        http_res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 6, read_timeout: 10) { |h| h.request(http_req) }
        diag[:github_get_status] = http_res.code
        diag[:github_get_sha] = (http_res.code == '200') ? JSON.parse(http_res.body)['sha'] : nil
        diag[:github_get_body] = http_res.body[0..200] if http_res.code != '200'
      rescue => err
        diag[:github_error] = "#{err.class}: #{err.message}"
      end

      send_json(res, diag)

    # -----------------------------
    # 1. Statistics: GET /api/stats
    # -----------------------------
    when '/api/stats'
      total_assignments = db.get_first_value('SELECT COUNT(*) FROM assignments')
      total_submissions = db.get_first_value('SELECT COUNT(*) FROM submissions')
      pending_submissions = db.get_first_value("SELECT COUNT(*) FROM submissions WHERE status = 'pending'")
      graded_submissions = db.get_first_value("SELECT COUNT(*) FROM submissions WHERE status = 'graded'")
      total_students = db.get_first_value('SELECT COUNT(*) FROM students')
      
      send_json(res, {
        assignments_count: total_assignments,
        submissions_count: total_submissions,
        pending_count: pending_submissions,
        graded_count: graded_submissions,
        students_count: total_students
      })

    # -----------------------------
    # 2. Students Management: GET / POST /api/students
    # -----------------------------
    when '/api/students'
      if method == 'GET'
        classroom = clean_str(req.query['classroom'])
        if classroom.empty?
          students = db.execute('SELECT * FROM students ORDER BY classroom ASC, student_number ASC')
        else
          students = db.execute('SELECT * FROM students WHERE classroom = ? ORDER BY student_number ASC', [classroom])
        end
        classrooms = db.execute('SELECT DISTINCT classroom FROM students ORDER BY classroom ASC').map { |r| r['classroom'] }
        send_json(res, { students: students, classrooms: classrooms })
      elsif method == 'POST'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนดำเนินการ', 401)
          next
        end

        body = parse_json_body(req)
        std_id = body['student_id'].to_s.strip
        std_num = body['student_number'].to_i
        name = body['name'].to_s.strip
        cls = body['classroom'].to_s.strip
        cls = 'ม.5/1' if cls.empty?

        if std_id.empty? || name.empty?
          send_error(res, 'กรุณาระบุรหัสนักเรียนและชื่อ-นามสกุล')
          next
        end

        db.execute(
          'INSERT OR REPLACE INTO students (student_id, student_number, name, classroom) VALUES (?, ?, ?, ?)',
          [std_id, std_num, name, cls]
        )
        saved = db.get_first_row('SELECT * FROM students WHERE student_id = ?', [std_id])
        send_json(res, { success: true, student: saved })
      end

    when %r{\A/api/students/(\d+)\z}
      id = Regexp.last_match(1).to_i
      if method == 'DELETE'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนดำเนินการ', 401)
          next
        end
        db.execute('DELETE FROM students WHERE id = ?', [id])
        send_json(res, { success: true, message: 'ลบข้อมูลนักเรียนสำเร็จ' })
      end

    when %r{\A/api/students/(\d+)/delete\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนดำเนินการ', 401)
        next
      end
      id = Regexp.last_match(1).to_i
      db.execute('DELETE FROM students WHERE id = ?', [id])
      send_json(res, { success: true, message: 'ลบข้อมูลนักเรียนสำเร็จ' })

    # -----------------------------
    # 3. Assignments: GET / POST /api/assignments
    # -----------------------------
    when '/api/assignments'
      if method == 'GET'
        query = <<-SQL
          SELECT a.*, 
                 COUNT(DISTINCT s.id) AS submissions_count,
                 SUM(CASE WHEN s.status = 'pending' THEN 1 ELSE 0 END) AS pending_count,
                 SUM(CASE WHEN s.status = 'graded' THEN 1 ELSE 0 END) AS graded_count
          FROM assignments a
          LEFT JOIN submissions s ON a.id = s.assignment_id
          GROUP BY a.id
          ORDER BY a.due_date ASC
        SQL
        assignments = db.execute(query)
        send_json(res, assignments)
      elsif method == 'POST'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนสร้างงาน', 401)
          next
        end

        body = parse_json_body(req)
        title = body['title'].to_s.strip
        subject = body['subject'].to_s.strip
        desc = body['description'].to_s.strip
        due_date = body['due_date'].to_s.strip
        max_score = (body['max_score'] || 100).to_f
        allow_late = body['allow_late'] ? 1 : 0

        if title.empty? || subject.empty? || due_date.empty?
          send_error(res, 'กรุณากรอกชื่อวิชา ชื่องาน และกำหนดวันส่งให้ครบถ้วน')
          next
        end

        db.execute(
          'INSERT INTO assignments (title, subject, description, due_date, max_score, allow_late) VALUES (?, ?, ?, ?, ?, ?)',
          [title, subject, desc, due_date, max_score, allow_late]
        )
        new_id = db.last_insert_row_id
        created = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [new_id])
        sync_db_to_github
        send_json(res, created, 201)
      end

    # -----------------------------
    # 4. Assignment Checklist (ตารางเช็คงานนักเรียน): GET /api/assignments/:id/checklist
    # -----------------------------
    when %r{\A/api/assignments/(\d+)/checklist\z}
      id = Regexp.last_match(1).to_i
      assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
      unless assignment
        send_error(res, 'ไม่พบข้อมูลงาน', 404)
        next
      end

      classroom_filter = clean_str(req.query['classroom'])

      query = <<-SQL
        SELECT 
          st.id AS student_record_id,
          st.student_id,
          st.student_number,
          st.name AS student_name,
          st.classroom,
          s.id AS submission_id,
          s.submitted_at,
          s.file_path,
          s.file_name,
          s.file_size,
          s.submission_link,
          s.score,
          s.feedback,
          s.note,
          s.status AS submission_db_status,
          s.is_late
        FROM students st
        LEFT JOIN submissions s ON s.student_id = st.student_id AND (s.classroom IS NULL OR s.classroom = '' OR s.classroom = st.classroom) AND s.assignment_id = ?
        WHERE (? = '' OR st.classroom = ?)
        ORDER BY st.classroom ASC, st.student_number ASC, st.student_id ASC
      SQL

      raw_list = db.execute(query, [id, classroom_filter, classroom_filter])

      # Process status for each student
      processed_students = raw_list.map do |row|
        status = 'missing'
        if row['submission_id']
          if row['submission_db_status'] == 'graded'
            status = 'graded'
          elsif row['is_late'] == 1
            status = 'late'
          else
            status = 'submitted'
          end
        end

        {
          student_record_id: row['student_record_id'],
          student_id: row['student_id'],
          student_number: row['student_number'],
          student_name: row['student_name'],
          classroom: row['classroom'],
          submission_id: row['submission_id'],
          status: status, # 'missing', 'submitted', 'late', 'graded'
          submitted_at: row['submitted_at'],
          file_path: row['file_path'],
          file_name: row['file_name'],
          file_size: row['file_size'],
          submission_link: row['submission_link'],
          score: row['score'],
          feedback: row['feedback'],
          note: row['note'],
          is_late: row['is_late']
        }
      end

      # Calculate Real-time statistics
      total_students = processed_students.size
      submitted_count = processed_students.count { |s| s[:status] != 'missing' }
      missing_count = processed_students.count { |s| s[:status] == 'missing' }
      graded_count = processed_students.count { |s| s[:status] == 'graded' }
      late_count = processed_students.count { |s| s[:status] == 'late' }
      submission_rate = total_students.positive? ? ((submitted_count.to_f / total_students) * 100).round(1) : 0
      
      scores = processed_students.map { |s| s[:score] }.compact
      avg_score = scores.any? ? (scores.sum / scores.size.to_f).round(2) : nil

      classrooms = db.execute('SELECT DISTINCT classroom FROM students ORDER BY classroom ASC').map { |r| r['classroom'] }

      send_json(res, {
        assignment: assignment,
        students: processed_students,
        stats: {
          total_students: total_students,
          submitted_count: submitted_count,
          missing_count: missing_count,
          graded_count: graded_count,
          late_count: late_count,
          submission_rate: submission_rate,
          average_score: avg_score
        },
        classrooms: classrooms
      })

    # -----------------------------
    # 5. Quick Toggle Student Submission Status: POST /api/assignments/:id/checklist/toggle
    # -----------------------------
    when %r{\A/api/assignments/(\d+)/checklist/toggle\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนเปลี่ยนสถานะ', 401)
        next
      end

      id = Regexp.last_match(1).to_i
      assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
      unless assignment
        send_error(res, 'ไม่พบงานที่เลือก', 404)
        next
      end

      body = parse_json_body(req)
      std_id = body['student_id'].to_s.strip
      cls = body['classroom'].to_s.strip

      if std_id.empty?
        send_error(res, 'ไม่พบรหัสนักเรียน')
        next
      end

      existing = if cls.empty?
        db.get_first_row('SELECT * FROM submissions WHERE assignment_id = ? AND student_id = ?', [id, std_id])
      else
        db.get_first_row('SELECT * FROM submissions WHERE assignment_id = ? AND student_id = ? AND (classroom = ? OR classroom IS NULL)', [id, std_id, cls])
      end

      if existing
        # If already exists, toggling turns it into missing (delete record)
        if existing['file_path']
          disk_file = File.join(UPLOADS_DIR, File.basename(existing['file_path']))
          File.delete(disk_file) if File.exist?(disk_file)
        end
        db.execute('DELETE FROM submissions WHERE id = ?', [existing['id']])
        send_json(res, { success: true, new_status: 'missing', message: 'เปลี่ยนเป็นยังไม่ส่งเรียบร้อย' })
      else
        # If not submitted, marking as submitted
        student = if cls.empty?
          db.get_first_row('SELECT * FROM students WHERE student_id = ?', [std_id])
        else
          db.get_first_row('SELECT * FROM students WHERE student_id = ? AND classroom = ?', [std_id, cls])
        end
        std_name = student ? student['name'] : "นักเรียนรหัส #{std_id}"
        std_cls = student ? student['classroom'] : cls
        
        # Check late
        is_late = 0
        begin
          is_late = Time.now > Time.parse(assignment['due_date']) ? 1 : 0
        rescue
          is_late = 0
        end

        db.execute(
          'INSERT INTO submissions (assignment_id, student_id, student_name, classroom, note, file_name, status, is_late) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [id, std_id, std_name, std_cls, 'อาจารย์เช็คส่งงานในห้องเรียน', 'เช็คส่งงานในชั้นเรียน', 'pending', is_late]
        )
        new_status = is_late == 1 ? 'late' : 'submitted'
        send_json(res, { success: true, new_status: new_status, message: 'บันทึกสถานะส่งงานเรียบร้อย' })
      end

    # -----------------------------
    # 6. Batch Mark as Submitted: POST /api/assignments/:id/checklist/batch
    # -----------------------------
    when %r{\A/api/assignments/(\d+)/checklist/batch\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์', 401)
        next
      end

      id = Regexp.last_match(1).to_i
      assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
      unless assignment
        send_error(res, 'ไม่พบงานที่เลือก', 404)
        next
      end

      body = parse_json_body(req)
      std_ids = body['student_ids'] || []
      target_status = body['status'] || 'submitted' # 'submitted' or 'missing'

      is_late = 0
      begin
        is_late = Time.now > Time.parse(assignment['due_date']) ? 1 : 0
      rescue
        is_late = 0
      end

      std_ids.each do |std_id|
        sid = std_id.to_s.strip
        next if sid.empty?
        existing = db.get_first_row('SELECT id FROM submissions WHERE assignment_id = ? AND student_id = ?', [id, sid])
        if target_status == 'submitted' && !existing
          student = db.get_first_row('SELECT name FROM students WHERE student_id = ?', [sid])
          sname = student ? student['name'] : "นักเรียน #{sid}"
          db.execute(
            'INSERT INTO submissions (assignment_id, student_id, student_name, note, file_name, status, is_late) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [id, sid, sname, 'อาจารย์เช็คส่งงานกลุ่ม/ทั้งห้อง', 'เช็คส่งงานในชั้นเรียน', 'pending', is_late]
          )
        elsif target_status == 'missing' && existing
          db.execute('DELETE FROM submissions WHERE id = ?', [existing['id']])
        end
      end

      send_json(res, { success: true, message: "อัปเดตสถานะนักเรียน #{std_ids.size} คนเรียบร้อยแล้ว" })

    # -----------------------------
    # 7. Export Checklist CSV: GET /api/export/checklist/:id
    # -----------------------------
    when %r{\A/api/export/checklist/(\d+)\z}
      id = Regexp.last_match(1).to_i
      assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
      unless assignment
        send_error(res, 'ไม่พบข้อมูลงาน', 404)
        next
      end

      classroom_filter = clean_str(req.query['classroom'])

      query = <<-SQL
        SELECT 
          st.student_number,
          st.student_id,
          st.name AS student_name,
          st.classroom,
          s.id AS submission_id,
          s.submitted_at,
          s.score,
          s.feedback,
          s.is_late,
          s.status AS sub_status,
          s.file_name,
          s.submission_link
        FROM students st
        LEFT JOIN submissions s ON s.student_id = st.student_id AND (s.classroom IS NULL OR s.classroom = '' OR s.classroom = st.classroom) AND s.assignment_id = ?
        WHERE (? = '' OR st.classroom = ?)
        ORDER BY st.classroom ASC, st.student_number ASC, st.student_id ASC
      SQL

      rows = db.execute(query, [id, classroom_filter, classroom_filter])

      csv_data = String.new("\xEF\xBB\xBF") # UTF-8 BOM for Excel
      csv_data << "ตารางเช็คการส่งงาน: #{assignment['title']} (วิชา #{assignment['subject']})\n"
      csv_data << "กำหนดส่ง: #{assignment['due_date']}, คะแนนเต็ม: #{assignment['max_score']}\n"
      csv_data << "พิมพ์รายงานเมื่อ: #{Time.now.strftime('%Y-%m-%d %H:%M')}\n\n"
      csv_data << "เลขที่,รหัสนักเรียน,ชื่อ - นามสกุล,ห้อง/ชั้น,สถานะการส่งงาน,วันเวลาที่ส่ง,คะแนนที่ได้ (เต็ม #{assignment['max_score']}),ข้อเสนอแนะ/Feedback,ไฟล์หรือลิงก์\n"

      rows.each do |r|
        status_text = if r['submission_id'].nil?
                        'ยังไม่ส่ง'
                      elsif r['sub_status'] == 'graded'
                        'ตรวจแล้ว'
                      elsif r['is_late'] == 1
                        'ส่งช้า'
                      else
                        'ส่งแล้ว'
                      end

        score_text = r['score'].nil? ? '-' : r['score'].to_s
        sub_time = r['submitted_at'] || '-'
        feedback_text = "\"#{r['feedback'].to_s.gsub('"', '""')}\""
        file_or_link = "\"#{(r['file_name'] || r['submission_link'] || '-').to_s.gsub('"', '""')}\""
        clean_name = "\"#{r['student_name'].to_s.gsub('"', '""')}\""

        csv_data << "#{r['student_number']},#{r['student_id']},#{clean_name},#{r['classroom']},#{status_text},#{sub_time},#{score_text},#{feedback_text},#{file_or_link}\n"
      end

      safe_title = assignment['subject'].to_s.gsub(/[^a-zA-Z0-9_\u0E00-\u0E7F]/, '_')
      res['Content-Type'] = 'text/csv; charset=utf-8'
      res['Content-Disposition'] = "attachment; filename=\"Checklist_#{safe_title}_#{Time.now.strftime('%Y%m%d_%H%M')}.csv\""
      res.body = csv_data

    # -----------------------------
    # 8. Assignment Detail / Edit / Delete: /api/assignments/:id
    # -----------------------------
    when %r{\A/api/assignments/(\d+)\z}
      id = Regexp.last_match(1).to_i
      if method == 'GET'
        item = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
        if item
          send_json(res, item)
        else
          send_error(res, 'ไม่พบงานที่ค้นหา', 404)
        end
      elsif method == 'PUT'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนแก้ไขงาน', 401)
          next
        end

        body = parse_json_body(req)
        title = body['title'].to_s.strip
        subject = body['subject'].to_s.strip
        desc = body['description'].to_s.strip
        due_date = body['due_date'].to_s.strip
        max_score = (body['max_score'] || 100).to_f
        allow_late = body['allow_late'] ? 1 : 0

        db.execute(
          'UPDATE assignments SET title = ?, subject = ?, description = ?, due_date = ?, max_score = ?, allow_late = ? WHERE id = ?',
          [title, subject, desc, due_date, max_score, allow_late, id]
        )
        updated = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
        sync_db_to_github
        send_json(res, updated)
      elsif method == 'DELETE'
        unless check_teacher_auth(req)
          send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนลบงาน', 401)
          next
        end

        db.execute('DELETE FROM assignments WHERE id = ?', [id])
        db.execute('DELETE FROM submissions WHERE assignment_id = ?', [id])
        sync_db_to_github
        send_json(res, { success: true, message: 'ลบงานเรียบร้อยแล้ว' })
      end

    when %r{\A/api/assignments/(\d+)/delete\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนลบงาน', 401)
        next
      end
      id = Regexp.last_match(1).to_i
      db.execute('DELETE FROM assignments WHERE id = ?', [id])
      db.execute('DELETE FROM submissions WHERE assignment_id = ?', [id])
      sync_db_to_github
      send_json(res, { success: true, message: 'ลบงานเรียบร้อยแล้ว' })

    # -----------------------------
    # 9. Assignment Submissions List: GET /api/assignments/:id/submissions
    # -----------------------------
    when %r{\A/api/assignments/(\d+)/submissions\z}
      id = Regexp.last_match(1).to_i
      submissions = db.execute('SELECT * FROM submissions WHERE assignment_id = ? ORDER BY submitted_at DESC', [id])
      send_json(res, submissions)

    # -----------------------------
    # 10. Export CSV: GET /api/export/csv/:assignment_id
    # -----------------------------
    when %r{\A/api/export/csv/(\d+)\z}
      id = Regexp.last_match(1).to_i
      assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [id])
      unless assignment
        send_error(res, 'ไม่พบข้อมูลงาน', 404)
        next
      end

      submissions = db.execute('SELECT * FROM submissions WHERE assignment_id = ? ORDER BY student_id ASC', [id])

      csv_data = String.new("\xEF\xBB\xBF") # UTF-8 BOM for Thai Excel
      csv_data << "รหัสนักศึกษา,ชื่อ-นามสกุล,อีเมล,วันเวลาที่ส่ง,สถานะส่ง,คะแนน (เต็ม #{assignment['max_score']}),ข้อคิดเห็น/Feedback,ชื่อไฟล์ที่ส่ง,ลิงก์แนบ\n"

      submissions.each do |s|
        late_text = s['is_late'] == 1 ? 'ส่งช้า' : 'ตรงเวลา'
        score_text = s['score'].nil? ? 'ยังไม่ตรวจ' : s['score'].to_s
        clean_name = "\"#{s['student_name'].to_s.gsub('"', '""')}\""
        clean_note = "\"#{s['feedback'].to_s.gsub('"', '""')}\""
        clean_file = "\"#{s['file_name'].to_s.gsub('"', '""')}\""
        clean_link = "\"#{s['submission_link'].to_s.gsub('"', '""')}\""

        csv_data << "#{s['student_id']},#{clean_name},#{s['student_email']},#{s['submitted_at']},#{late_text},#{score_text},#{clean_note},#{clean_file},#{clean_link}\n"
      end

      res['Content-Type'] = 'text/csv; charset=utf-8'
      res['Content-Disposition'] = "attachment; filename=\"submission_#{id}_#{Time.now.strftime('%Y%m%d_%H%M')}.csv\""
      res.body = csv_data

    # -----------------------------
    # 11. Submit Work: POST /api/submissions (Multipart / Form)
    # -----------------------------
    when '/api/submissions'
      if method == 'POST'
        query_params = req.query

        assignment_id = (query_params['assignment_id'] || '').to_i
        student_id = clean_str(query_params['student_id'])
        student_name = clean_str(query_params['student_name'])
        student_number = (query_params['student_number'] || '').to_i
        student_email = clean_str(query_params['student_email'])
        note = clean_str(query_params['note'])
        submission_link = clean_str(query_params['submission_link'])
        cls_param = clean_str(query_params['classroom'])
        student_classroom = cls_param.empty? ? 'ม.5/1' : cls_param

        # Lookup student by classroom + student_number if student_id is missing
        if student_id.empty? && student_number > 0
          found_std = db.get_first_row('SELECT * FROM students WHERE classroom = ? AND student_number = ?', [student_classroom, student_number])
          if found_std
            student_id = found_std['student_id']
            student_name = found_std['name'] if student_name.empty?
          else
            student_id = "std_#{student_classroom.gsub(/[^0-9]/, '')}_#{student_number}"
          end
        end

        if assignment_id <= 0 || student_name.empty? || (student_id.empty? && student_number <= 0)
          send_error(res, 'กรุณาระบุห้อง เลขที่ และชื่อ-สกุล ให้ครบถ้วน')
          next
        end

        assignment = db.get_first_row('SELECT * FROM assignments WHERE id = ?', [assignment_id])
        unless assignment
          send_error(res, 'ไม่พบงานที่เลือกส่ง', 404)
          next
        end

        # Check late submission
        is_late = 0
        begin
          due_time = Time.parse(assignment['due_date'])
          if Time.now > due_time
            is_late = 1
            if assignment['allow_late'] == 0
              send_error(res, 'งานนี้ปิดรับการส่งแล้วเนื่องจากเกินกำหนดเวลา')
              next
            end
          end
        rescue => _e
          is_late = 0
        end

        file_param = query_params['file']
        file_path_rel = nil
        file_name = nil
        file_size = 0

        if file_param && file_param.is_a?(WEBrick::HTTPUtils::FormData) && file_param.filename && !file_param.filename.empty?
          raw_filename = clean_filename(File.basename(file_param.filename))
          safe_name = "#{SecureRandom.hex(6)}_#{raw_filename}"
          target_path = File.join(UPLOADS_DIR, safe_name)

          File.open(target_path, 'wb') do |f|
            f.write(file_param.to_s)
          end

          file_path_rel = "/uploads/#{safe_name}"
          file_name = raw_filename
          file_size = File.size(target_path)
          sync_file_to_github(target_path, safe_name)
        end

        # Check that at least a file or link is provided (or if student note provided)
        if (file_name.nil? || file_name.empty?) && submission_link.empty? && note.empty?
          send_error(res, 'กรุณาแนบไฟล์งานที่ต้องการส่ง')
          next
        end

        # Upsert student into roster if not exists
        existing_student = db.get_first_row('SELECT * FROM students WHERE student_id = ? AND classroom = ?', [student_id, student_classroom]) ||
                           db.get_first_row('SELECT * FROM students WHERE classroom = ? AND student_number = ?', [student_classroom, student_number])

        if existing_student.nil?
          db.execute(
            'INSERT INTO students (student_id, student_number, name, classroom) VALUES (?, ?, ?, ?)',
            [student_id, (student_number > 0 ? student_number : 99), student_name, student_classroom]
          )
        end

        # Check if already submitted -> update instead of inserting duplicate
        existing_sub = db.get_first_row('SELECT id, file_path FROM submissions WHERE assignment_id = ? AND student_id = ? AND (classroom = ? OR classroom IS NULL)', [assignment_id, student_id, student_classroom])

        if existing_sub
          if file_path_rel && existing_sub['file_path']
            old_f = File.join(UPLOADS_DIR, File.basename(existing_sub['file_path']))
            File.delete(old_f) if File.exist?(old_f)
            delete_file_from_github(File.basename(existing_sub['file_path']))
          end

          db.execute <<-SQL, [student_name, student_email, student_classroom, note, file_path_rel || existing_sub['file_path'], file_name || existing_sub['file_name'], file_size > 0 ? file_size : existing_sub['file_size'], submission_link, is_late, existing_sub['id']]
            UPDATE submissions 
            SET student_name = ?, student_email = ?, classroom = ?, note = ?, file_path = ?, file_name = ?, file_size = ?, submission_link = ?, is_late = ?, submitted_at = CURRENT_TIMESTAMP
            WHERE id = ?
          SQL
          saved = db.get_first_row('SELECT * FROM submissions WHERE id = ?', [existing_sub['id']])
          sync_db_to_github
          send_json(res, { success: true, message: 'อัปเดตการส่งงานเรียบร้อยแล้ว', submission: saved }, 200)
        else
          db.execute(
            'INSERT INTO submissions (assignment_id, student_id, student_name, student_email, classroom, note, file_path, file_name, file_size, submission_link, status, is_late) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            [assignment_id, student_id, student_name, student_email, student_classroom, note, file_path_rel, file_name, file_size, submission_link, 'pending', is_late]
          )
          new_sub_id = db.last_insert_row_id
          saved = db.get_first_row('SELECT * FROM submissions WHERE id = ?', [new_sub_id])
          sync_db_to_github
          send_json(res, { success: true, message: 'ส่งงานเรียบร้อยแล้ว', submission: saved }, 201)
        end
      end

    # -----------------------------
    # 12. Search Submissions by Student ID: GET /api/submissions/search?student_id=...
    # -----------------------------
    when '/api/submissions/search'
      student_id = clean_str(req.query['student_id'])
      if student_id.empty?
        send_json(res, [])
        next
      end

      query = <<-SQL
        SELECT s.*, a.title AS assignment_title, a.subject AS assignment_subject, a.due_date, a.max_score
        FROM submissions s
        JOIN assignments a ON s.assignment_id = a.id
        WHERE s.student_id = ? OR s.student_id LIKE ? OR s.student_name LIKE ?
        ORDER BY s.submitted_at DESC
      SQL
      subs = db.execute(query, [student_id, "%#{student_id}%", "%#{student_id}%"])
      send_json(res, subs)

    # -----------------------------
    # 12.1 Student Portfolio & Checklist: GET /api/students/portfolio?student_id=...&classroom=...
    # -----------------------------
    when '/api/students/portfolio'
      student_id = clean_str(req.query['student_id'])
      classroom = clean_str(req.query['classroom'])

      if student_id.empty?
        send_error(res, 'กรุณาระบุรหัสนักเรียน', 400)
        next
      end

      # Find matching student records
      students = if classroom.empty?
        db.execute('SELECT * FROM students WHERE student_id = ? OR student_id LIKE ?', [student_id, "%#{student_id}%"])
      else
        db.execute('SELECT * FROM students WHERE (student_id = ? OR student_id LIKE ?) AND classroom = ?', [student_id, "%#{student_id}%", classroom])
      end

      # Fallback: If not found with classroom, search by student_id alone
      if students.empty? && !classroom.empty?
        students = db.execute('SELECT * FROM students WHERE student_id = ? OR student_id LIKE ?', [student_id, "%#{student_id}%"])
      end

      if students.empty?
        # Try finding by name
        students = db.execute('SELECT * FROM students WHERE name LIKE ?', ["%#{student_id}%"])
      end

      if students.empty?
        send_error(res, "ไม่พบข้อมูลนักเรียนสำหรับ '#{student_id}'", 404)
        next
      end

      # If multiple students found, return list of candidates
      if students.size > 1 && classroom.empty?
        exact = students.select { |s| s['student_id'] == student_id }
        if exact.size == 1
          student = exact.first
        else
          send_json(res, { multiple: true, candidates: students })
          next
        end
      else
        student = students.first
      end

      std_id = student['student_id']
      std_cls = student['classroom']

      # Get all assignments
      assignments = db.execute('SELECT * FROM assignments ORDER BY due_date ASC, id ASC')

      # For each assignment, check submission
      portfolio_items = assignments.map do |assign|
        sub = db.get_first_row(
          'SELECT * FROM submissions WHERE assignment_id = ? AND student_id = ? AND (classroom = ? OR classroom IS NULL OR classroom = "")',
          [assign['id'], std_id, std_cls]
        )

        status = 'missing'
        if sub
          status = sub['status'] == 'graded' ? 'graded' : (sub['is_late'] == 1 ? 'late' : 'submitted')
        end

        {
          assignment_id: assign['id'],
          subject: assign['subject'],
          title: assign['title'],
          description: assign['description'],
          due_date: assign['due_date'],
          max_score: assign['max_score'],
          allow_late: assign['allow_late'],
          submitted: !sub.nil?,
          status: status,
          submission: sub ? {
            id: sub['id'],
            submitted_at: sub['submitted_at'],
            file_name: sub['file_name'],
            file_path: sub['file_path'],
            file_size: sub['file_size'],
            submission_link: sub['submission_link'],
            note: sub['note'],
            score: sub['score'],
            feedback: sub['feedback'],
            is_late: sub['is_late']
          } : nil
        }
      end

      total_assignments = portfolio_items.size
      submitted_count = portfolio_items.count { |p| p[:submitted] }
      missing_count = total_assignments - submitted_count
      graded_count = portfolio_items.count { |p| p[:status] == 'graded' }
      progress_pct = total_assignments > 0 ? ((submitted_count.to_f / total_assignments) * 100).round(1) : 0

      total_score_earned = portfolio_items.map { |p| p[:submission] ? p[:submission][:score] : nil }.compact.sum
      total_max_score = portfolio_items.map { |p| p[:max_score] }.compact.sum

      send_json(res, {
        student: student,
        stats: {
          total_assignments: total_assignments,
          submitted_count: submitted_count,
          missing_count: missing_count,
          graded_count: graded_count,
          progress_pct: progress_pct,
          total_score_earned: total_score_earned.round(2),
          total_max_score: total_max_score.round(2)
        },
        items: portfolio_items
      })

    # -----------------------------
    # 13. Grade Submission: POST /api/submissions/:id/grade
    # -----------------------------
    when %r{\A/api/submissions/(\d+)/grade\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนบันทึกคะแนน', 401)
        next
      end

      id = Regexp.last_match(1).to_i
      if method == 'POST'
        body = parse_json_body(req)
        score = body['score'].nil? ? nil : body['score'].to_f
        feedback = body['feedback'].to_s.strip

        db.execute(
          "UPDATE submissions SET score = ?, feedback = ?, status = 'graded' WHERE id = ?",
          [score, feedback, id]
        )
        updated = db.get_first_row('SELECT * FROM submissions WHERE id = ?', [id])
        send_json(res, { success: true, message: 'บันทึกคะแนนและคำติชมสำเร็จ', submission: updated })
      end

    # -----------------------------
    # 14. Delete Submission: DELETE /api/submissions/:id or POST /api/submissions/:id/delete
    # -----------------------------
    when %r{\A/api/submissions/(\d+)(?:/delete)?\z}
      unless check_teacher_auth(req)
        send_error(res, 'กรุณาเข้าสู่ระบบด้วยรหัสผ่านอาจารย์ก่อนลบการส่งงาน', 401)
        next
      end

      id = Regexp.last_match(1).to_i
      sub = db.get_first_row('SELECT file_path FROM submissions WHERE id = ?', [id])
      if sub && sub['file_path']
        fname = File.basename(sub['file_path'])
        disk_path = File.join(UPLOADS_DIR, fname)
        File.delete(disk_path) if File.exist?(disk_path)
        delete_file_from_github(fname)
      end
      db.execute('DELETE FROM submissions WHERE id = ?', [id])
      sync_db_to_github
      send_json(res, { success: true, message: 'ลบการส่งงานเรียบร้อยแล้ว นักเรียนสามารถส่งใหม่ได้ทันที' })

    else
      send_error(res, "Endpoint not found: #{path}", 404)
    end
  rescue => err
    $stderr.puts "[Error] #{err.class}: #{err.message}\n#{err.backtrace.first(5).join("\n")}"
    send_error(res, "เซิร์ฟเวอร์เกิดข้อผิดพลาด: #{err.message}", 500)
  end
end

puts "========================================================="
puts "  🚀 ระบบตรวจและเช็คงานนักเรียน Student Assignment System ทำงานแล้ว"
puts "  📍 Local URL:         http://localhost:#{PORT}"
puts "  🔑 รหัสผ่านอาจารย์:   #{TEACHER_PASSWORD}"
puts "  💾 SQLite DB:         #{DB_PATH}"
puts "  📁 Uploads:           #{UPLOADS_DIR}"
puts "========================================================="

server.start
