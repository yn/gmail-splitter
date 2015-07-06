require "gmail/imap_extensions"
require 'net/imap'
require './setup.rb'
class DecThread
  attr_accessor :thread_id
  def initialize(thread_id)
    self.thread_id = thread_id.strip
  end
  def dec_thread
    self
  end
  def hex_thread
    HexThread.new thread_id.to_i(10).to_s(16)
  end
  def to_s
    thread_id
  end
end
class HexThread
  attr_accessor :thread_id
  def initialize(thread_id)
    self.thread_id = thread_id.strip
  end
  def dec_thread
    DecThread.new thread_id.to_i(16).to_s(10)
  end
  def hex_thread
    self
  end
  def to_s
    thread_id
  end
end
class GmailSplitter
  extend Forwardable
  def_delegators :@gmail, :search, :fetch, :store, :uid_store, :append, :copy, :select
  attr_reader :gmail
  def initialize(gmail)
    @gmail = gmail
  end
  module Common
    def thread_id_label(t)
      "thread/#{t.hex_thread.to_s}"
    end
    def gmail_search_thread_id_label(t)
      "label:#{thread_id_label t} -in:trash"
    end
  end
  include Common

  def check_thread_id_label(t)
    seq_nos = search(["X-GM-THRID", t.dec_thread.to_s])
    return [:not_ok, :bad_thread_id] if seq_nos.empty?
    fetch_data_seq = fetch(seq_nos, %w(X-GM-LABELS))
    fetch_data_seq.all? do |x|
      x.attr["X-GM-LABELS"].include? thread_id_label(t)
    end ? [:ok] : [:not_ok, :needs_apply, fetch_data_seq]
  end

  def apply_thread_id_label(t)
    result, reason, fetch_data_seq = check_thread_id_label t
    return [:ok, :already_ok] if result == :ok
    if result == :not_ok && reason == :needs_apply
      fetch_data_seq.each do |fetch_data|
        puts fetch_data.attr["X-GM-LABELS"].inspect
        #store(fetch_data.seqno, "X-GM-LABELS", fetch_data.attr["X-GM-LABELS"] << thread_id_label(t))
      end
      return check_thread_id_label(t).first == :ok ? [:ok, :applied] : [:not_ok, :apply_failed]
    else
      return [result, reason]
    end
  end

  def check_ok_to_split(t)
    result, reason = check_thread_id_label(t)
    return [result, reason] if result != :ok
    seq_nos = search ["X-GM-RAW", gmail_search_thread_id_label(t)]
    fetch_data_seq = fetch seq_nos, %w(X-GM-THRID X-GM-LABELS ENVELOPE INTERNALDATE)
    return [:not_ok, :multiple_threads] unless fetch_data_seq.map {|x| x.attr["X-GM-THRID"]}.uniq.length == 1
    starred, unstarred = fetch_data_seq.partition do |fetch_data|
      fetch_data.attr["X-GM-LABELS"].include?(:Starred)
    end
    return [:not_ok, :missing_starred] if starred.empty?
    return [:not_ok, :missing_unstarred] if unstarred.empty?
    return [:ok, :can_split, fetch_data_seq, starred, unstarred]
  end

  def simulate_thread_splitting(t)
    result, reason, fetch_data_seq, starred, unstarred = check_ok_to_split(t)
    return [result, reason] if result != :ok
    puts "Before"
    fetch_data_seq.each do |fetch_data|
      print_thread(fetch_data)
    end
    puts "After Starred:"
    starred.each do |fetch_data|
      print_thread(fetch_data)
    end
    puts "After Unstarred:"
    unstarred.each do |fetch_data|
      print_thread(fetch_data, downcase:true)
    end
    return [:ok]
  end

  def print_thread(fetch_data, downcase:false)
    envelope = fetch_data.attr["ENVELOPE"]
    from = envelope.from[0].name
    subject = envelope.subject
    subject.downcase! if downcase
    labels = fetch_data.attr["X-GM-LABELS"]
    date = envelope.date
    puts "#{date}:#{from}:#{subject}:#{labels}"
  end

  def split_thread(t)
    result, reason, fetch_data_seq, starred, unstarred = check_ok_to_split(t)
    return [result, reason] if result != :ok
    unstarred_seqno_seq = unstarred.map {|x| x.seqno}
    unstarred_fetch_data_seq = fetch(unstarred_seqno_seq, %w(X-GM-LABELS ENVELOPE RFC822 UID FLAGS))
    new_msg_labels = {}
    unstarred_fetch_data_seq.each do |x|
      m = Mail.new x.attr["RFC822"].to_s
      m.subject = m.subject.downcase
      m.date = x.attr["ENVELOPE"].date unless m.date

      m_format = Mail.new x.attr["RFC822"].to_s
      m_format.date = x.attr["ENVELOPE"].date

      working_str = m_format.date.strftime('%d-%b-%Y %H:%M:%S %z')
      append_result = append thread_id_label(t), m.to_s, x.attr["FLAGS"], working_str
      new_seqno = append_result.data.code.data.split[1] rescue nil
      new_msg_labels[new_seqno.to_i] = x.attr["X-GM-LABELS"] if new_seqno
    end
    copy(unstarred.map {|x| x.seqno}, "[Gmail]/Trash")
    begin
      select(thread_id_label(t))
      new_msg_labels.each do |key, value|
        uid_store key, "X-GM-LABELS", value
      end
    ensure
      select("[Gmail]/All Mail")
    end
  end



  def yn
    cmd = nil
    loop do
      puts "Apply? Y/N"
      cmd = gets.chomp.downcase
      break if ["y", "n"].include? (cmd)
    end
    return cmd
  end

  def input
    while true
      puts "Enter a thread id"
      t =  HexThread.new(gets.chomp)
      result, reason = apply_thread_id_label t
      puts reason
      redo if result != :ok
      result, reason = simulate_thread_splitting t
      puts reason
      redo if result != :ok
      if yn == "y"
        split_thread(t)
        #LEFTOVER:
        #DISPLAY the two threads, old and new
      end
    end
  end
end
Net::IMAP.debug = true
load "./password.rb"
puts $password
$gmail = Net::IMAP.new('imap.gmail.com',port:993,ssl:true)
Gmail::ImapExtensions.patch_net_imap_response_parser
$gmail.login("yuri.niyazov@gmail.com",$password)
$gmail.select("SplitTest")
GmailSplitter.new($gmail).input
