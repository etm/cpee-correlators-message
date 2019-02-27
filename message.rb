#!/usr/bin/ruby
#
# This file is part of centurio.work/ing/correlators/message
#
# centurio.work/ing/correlators/message is free software: you can redistribute
# it and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# centurio.work/ing/correlators/message is distributed in the hope that it will
# be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# centurio.work/ing/correlators/message (file COPYING in the main directory). If
# not, see <http://www.gnu.org/licenses/>.

require 'rubygems'
require 'json'
require 'riddl/server'
require 'riddl/client'
require 'securerandom'
require 'redis'
require 'pp'

require_relative 'includes/send'

class Condition < Riddl::Implementation
  include Send

  def response
    redis = @a[0]
    mess  = "message:" + @p[0].value

    if redis.exists(mess)
      val = redis.get(mess)
      redis.del(mess)
      send @h['CPEE_CALLBACK'], val
    else
      uuid = SecureRandom.uuid
      redis.multi
      redis.rpush("condition:" + @p[0].value,uuid)
      redis.set("value:#{uuid}",@h['CPEE_CALLBACK'])
      redis.set("value:condition:#{uuid}",@p[0].value)
      if @p[1].value.to_i > 0
        redis.set("value:ttl:#{uuid}",(Time.now + @p[1].value.to_i).to_i)
      end
      redis.exec
    end
    @headers << Riddl::Header.new('CPEE_CALLBACK','true')
    Riddl::Parameter::Simple.new("uuid",uuid)
  end
end

class DeleteCondition < Riddl::Implementation
  include Send

  def response
    redis = @a[0]
    uuid = @p[0].value

    cond = redis.get("value:condition:#{uuid}")
    cb   = redis.get("value:#{uuid}")

    redis.multi
    redis.del("value:condition:#{uuid}")
    redis.del("value:ttl:#{uuid}")
    redis.del("value:#{uuid}")
    redis.del("con:#{uuid}")
    redis.lrem("condition:#{cond}",0,uuid)
    redis.exec

    send(cb,'','deleted')
  end
end

class Message < Riddl::Implementation #{{{
  include Send

  def response
    redis = @a[0]
    cond  = "condition:" + @p[0].value

    if redis.exists(cond)
      while uuid = redis.lpop(cond)
        send redis.get("value:#{uuid}"), @p[1].value
        redis.del("value:#{uuid}")
      end
    else
      uuid = SecureRandom.uuid
      mess = "message:" + @p[0].value
      if @p[2].value.to_i > 0
        redis.setex(mess,@p[2].value.to_i,@p[1].value)
      else
        redis.set(mess,@p[1].value)
      end
    end
  end
end #}}}

options = {
  :host => 'centurio.work',
  :port => 9308,
  :secure => false
}

Riddl::Server.new(File.join(__dir__,'/message.xml'), options) do |opts|
  accessible_description true
  cross_site_xhr true

  opts[:redis] = Redis.new(path: "/tmp/redis.sock", db: 10)

  on resource do
    on resource 'push' do
      run Message opts[:redis] if post 'message'
    end
    on resource 'fetch' do
      run Condition, opts[:redis] if get 'criteria'
      run DeleteCondition, opts[:redis] if delete 'criteria_del'
    end
  end
end.loop!
