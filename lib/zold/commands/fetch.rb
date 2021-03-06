# frozen_string_literal: true

# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'uri'
require 'json'
require 'time'
require 'tempfile'
require 'slop'
require 'rainbow'
require 'concurrent/atomics'
require_relative 'args'
require_relative '../log'
require_relative '../age'
require_relative '../http'
require_relative '../size'
require_relative '../score'
require_relative '../json_page'
require_relative '../copies'

# FETCH command.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # FETCH pulling command
  class Fetch
    def initialize(wallets:, remotes:, copies:, log: Log::Quiet.new)
      @wallets = wallets
      @remotes = remotes
      @copies = copies
      @log = log
    end

    def run(args = [])
      opts = Slop.parse(args, help: true, suppress_errors: true) do |o|
        o.banner = "Usage: zold fetch [ID...] [options]
Available options:"
        o.bool '--ignore-score-weakness',
          'Don\'t complain when their score is too weak',
          default: false
        o.array '--ignore-node',
          'Ignore this node and don\'t fetch from it',
          default: []
        o.bool '--quiet-if-absent',
          'Don\'t fail if the wallet is absent in all remote nodes',
          default: false
        o.string '--network',
          'The name of the network we work in',
          default: 'test'
        o.bool '--help', 'Print instructions'
      end
      mine = Args.new(opts, @log).take || return
      (mine.empty? ? @wallets.all : mine.map { |i| Id.new(i) }).each do |id|
        fetch(id, Copies.new(File.join(@copies, id)), opts)
      end
    end

    private

    def fetch(id, cps, opts)
      start = Time.now
      total = Concurrent::AtomicFixnum.new
      nodes = Concurrent::AtomicFixnum.new
      done = Concurrent::AtomicFixnum.new
      @remotes.iterate(@log) do |r|
        nodes.increment
        total.increment(fetch_one(id, r, cps, opts))
        done.increment
      end
      raise "There are no remote nodes, run 'zold remote reset'" if nodes.value.zero?
      raise "No nodes out of #{nodes.value} have the wallet #{id}" if done.value.zero? && !opts['quiet-if-absent']
      @log.info("#{done.value} copies of #{id} fetched in #{Age.new(start)} with the total score of \
#{total.value} from #{nodes.value} nodes")
      @log.debug("#{cps.all.count} local copies:")
      cps.all.each do |c|
        wallet = Wallet.new(c[:path])
        @log.debug("  #{c[:name]}: #{c[:score]} #{wallet.balance}/#{wallet.txns.count}t/\
#{wallet.digest[0, 6]}/#{Size.new(File.size(c[:path]))}/#{Age.new(File.mtime(c[:path]))}")
      end
    end

    def fetch_one(id, r, cps, opts)
      start = Time.now
      if opts['ignore-node'].include?(r.to_s)
        @log.debug("#{r} ignored because of --ignore-node")
        return 0
      end
      uri = "/wallet/#{id}"
      res = r.http(uri).get
      raise "Wallet #{id} not found" if res.code == '404'
      r.assert_code(200, res)
      json = JsonPage.new(res.body, uri).to_hash
      score = Score.parse_json(json['score'])
      r.assert_valid_score(score)
      r.assert_score_ownership(score)
      r.assert_score_strength(score) unless opts['ignore-score-weakness']
      Tempfile.open(['', Wallet::EXTENSION]) do |f|
        body = json['body']
        File.write(f, body)
        wallet = Wallet.new(f.path)
        wallet.refurbish
        if wallet.protocol != Zold::PROTOCOL
          raise "Protocol #{wallet.protocol} doesn't match #{Zold::PROTOCOL} in #{id}"
        end
        if wallet.network != opts['network']
          raise "The wallet #{id} is in network '#{wallet.network}', while we are in '#{opts['network']}'"
        end
        if wallet.balance.negative? && !wallet.root?
          raise "The balance of #{id} is #{wallet.balance} and it's not a root wallet"
        end
        copy = cps.add(File.read(f), score.host, score.port, score.value)
        @log.info("#{r} returned #{Size.new(body.length)}/#{wallet.balance}/#{wallet.txns.count}t/\
#{digest(json)}/#{Age.new(json['mtime'])}/#{json['copies']}c \
as copy #{copy} of #{id} in #{Age.new(start)}: #{Rainbow(score.value).green} (#{json['version']})")
      end
      score.value
    end

    def digest(json)
      hash = json['digest']
      return '?' if hash.nil?
      hash[0, 6]
    end
  end
end
