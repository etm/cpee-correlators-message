#!/usr/bin/ruby
#
# This file is part of centurio.work/data/provisioner/north.
#
# centurio.work/data/provisioner/north is free software: you can redistribute
# it and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# centurio.work/data/provisioner/north is distributed in the hope that it will
# be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# centurio.work/data/provisioner/north (file COPYING in the main directory). If
# not, see <http://www.gnu.org/licenses/>.

require 'json'
require 'redis'
require 'riddl/client'
require 'daemonite'

require_relative 'includes/send'

Daemonite.new do |opts|
  redis = Redis.new(path: "/tmp/redis.sock", db: 10)

  run do
    redis.scan_each(:match => "value:ttl:*") do |key|
      uuid = key[10..-1]

      cond = redis.get("value:condition:#{uuid}")
      cb   = redis.get("value:#{uuid}")

      redis.multi do |multi|
        multi.del("value:condition:#{uuid}")
        multi.del("value:ttl:#{uuid}")
        multi.del("value:#{uuid}")
        multi.del("con:#{uuid}")
        multi.lrem("condition:#{cond}",0,uuid)
      end

      SendCallback::send cb, '', 'expired'
    end
    sleep 1
  end
end.loop!
