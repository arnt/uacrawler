require 'bundler/setup'
require 'mechanize'
require "logger"
require 'byebug'
require 'erb'

include ERB::Util

@log = Logger.new "/tmp/mechanize.txt"
@log.level = Logger::DEBUG
@end = Time.now + 6

def relevant?(uri)
  (uri != nil &&
   @scheme == uri.scheme &&
   @host == uri.host &&
   @port == uri.port)
end

def unseen?(uri)
  (!@unprocessed.include?(uri) && !@processed.include?(uri))
end

def emailish?(input)
  ((input.kind_of?(Mechanize::Form::Field) && input.type == "email") ||
   (input.kind_of?(Mechanize::Form::Text) && input.name =~ /mail/))
end

class Software
  def initialize(name, url, condition)
    @name = name
    @homepage = url
    @condition = condition
  end

  def name()
    @name
  end

  def homepage()
    @homepage
  end

  def uaReady?(page)
    false
  end

  def uaUnready?(page)
    false
  end

  def condition()
    @condition
  end
end

class UnreadySoftware < Software
  def initialize(name, home)
    super(name, home, nil)
  end
  def uaUnready?(page)
    true
  end
end

WORDPRESS = UnreadySoftware.new("Wordpress", "https://wordpress.org")
CF7 = UnreadySoftware.new("Contact Form 7", "https://contactform7.com")

class EmailishForm
  def initialize(p)
    @page = p
  end
  def page()
    @page
  end
  def uaReady?()
    false
  end
  def report
    @report ||= computeReport
  end
  def computeReport
    result = []
    @software ||= detectSoftware
    bad = @software.select{ |s| !s.uaReady?(@page) }
    if !bad.empty? then
      bad.each do |s|
        if s.uaUnready?(@page)
          result << "<li>This form uses <a href=\"#{s.homepage}\">#{s.name}</a>, which was not UA-ready at the time of writing."
        else
          result << "<li>This form uses #{s.name}, which is UA-ready if #{s.condition}. This software cannot test that (yet)."
        end
      end
    elsif @software.empty? then
      result << "<li>This form may or may not be UA-ready; the software behind it could not be detected."
    else
      nil
    end
    " This form appears to ask for an email address. <ul> #{result.join(' ')} </ul>You could try to enter dømi@dømi.fo and see if the form works as expected." unless result.empty?
  end

  def detectSoftware
    result = []
    result << WORDPRESS if detectWordpress;
    result << CF7 if detectCF7
    result
  end

  def detectWordpress
    @page.image_urls.any? do |u|
      u.host == @page.uri.host &&
        u.path.kind_of?(String) &&
        u.path.match?(/^\/wp-/)
    end
  end

  def detectCF7
    @page.forms.any?{|f| f.action.match?(/\#wpcf7/)}
  end
end

def process(page)
 distance = @distances[page.uri]
  if page.kind_of?(Mechanize::Page) && distance < 3 then
    links = page.links
              .map{ |l| l.resolved_uri rescue nil }
              .select{ |u| relevant?(u) }
              .map{ |u| u.fragment = nil ; u }
    links.each { |u| @distances[u] = [distance + 1, (@distances[u] || 4)].min }
    links.select{ |u| unseen?(u) }.each { |u| @unprocessed.add(u) }
  end
  if page.forms.any? { |f| f.fields.any? { |i| emailish?(i) } } then
    @forms[page.uri] = EmailishForm.new(page)
  end
end

def mechanize()
  m = Mechanize.new{ |a| a.log = @log }
  m.user_agent = 'uasg.tech-UAChecker/0.1'
  m
end

start = mechanize.get(ARGV[0])

@host = start.uri.host
@port = start.uri.port
@scheme = start.uri.scheme

@processed = Set.new
@unprocessed = Set.new
@forms = {}
@distances = { start.uri => 0}

process(start)
@processed.add(start.uri)

progress = true;
while progress do
  progress = false
  i = 0;
  queues = []
  @distances
    .sort_by{ |k, _v| k.path.length }
    .sort_by{ |_k, v| v }
    .map{ |k, _v| k }
    .select{ |u| !@processed.include?(u) }.each do |uri|
      queues[i] ||= []
      queues[i] << uri
      i = i + 1;
      i = 0 if i > 9;
  end
  threads = []
  @fetched = []
  @lock = Mutex.new
  queues.each do |q|
    threads << Thread.new do
      m = mechanize
      m.redirect_ok = false
      m.request_headers = {
        'Accept' => 'text/html',
        'Referer' => start.canonical_uri
      }
      q.each do |uri|
        if @processed.count + @fetched.count + queues.count < 53 && Time.now < @end then
          page = m.get(uri) rescue nil
          if page.kind_of?(Mechanize::Page) then
            @lock.synchronize { @fetched << page }
          end
        end
      end
    end
  end
  threads.each { |t| t.join }
  @fetched.each do |page|
    @processed.add(page.uri)
    process(page) rescue nil
    progress = true
  end
end


puts "<p>Checked #{@processed.count} pages on #{@host} and found #{@forms.count} relevant forms.\n"

bad = @forms.values.select { |f| !f.uaReady? }
if @forms.empty? then
  puts "#{@host} appears to have no UA-relevant content.\n"
elsif bad.empty? then
  puts "#{@host} appears to be UA-ready.\n"
else
  repeated = 0
  problems = []
  puts "<ul>\n"
  bad.each do |f|
    problem = f.report
    if problems.include?(problem) then
      repeated = repeated + 1
    else
      puts "<li><a href=\"#{f.page.uri}\">#{h(f.page.title)}</a>: #{problem}\n"
      problems << problem
    end
  end
  puts "</ul>\n"
  if repeated > 0 then
    puts "<p>#{repeated} more pages have the same potential problems.\n"
  end
end
