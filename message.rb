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
  def response
    redis = @a[0]
    mess  = "message:" + @p[0].value
    del = (@p[2].value == 'true' ? true : false) rescue true

    if redis.exists?(mess)
      val = redis.get(mess)
      redis.del(mess) if del
      Riddl::Parameter::Complex.new('message','application/json',JSON.generate({ "message" => val, "delivery" => 'source' }))
    else
      uuid = SecureRandom.uuid
      redis.multi do |multi|
        multi.rpush("condition:" + @p[0].value,uuid)
        multi.set("value:#{uuid}",@h['CPEE_CALLBACK'])
        multi.set("value:condition:#{uuid}",@p[0].value)
        multi.set("value:del:#{uuid}",del)
        if @p[1].value.to_i > 0
          multi.set("value:ttl:#{uuid}",(Time.now + @p[1].value.to_i).to_i)
        end
      end
      @headers << Riddl::Header.new('CPEE_CALLBACK','true')
      Riddl::Parameter::Simple.new("slotid",uuid)
    end
  end
end

class DeleteCondition < Riddl::Implementation
  def response
    redis = @a[0]
    uuid = @p[0].value

    cond = redis.get("value:condition:#{uuid}")
    cb   = redis.get("value:#{uuid}")

    redis.multi do |multi|
      multi.del("value:condition:#{uuid}")
      multi.del("value:ttl:#{uuid}")
      multi.del("value:del:#{uuid}")
      multi.del("value:#{uuid}")
      multi.del("con:#{uuid}")
      multi.lrem("condition:#{cond}",0,uuid)
    end

    SendCallback::send cb, '', 'deleted' unless cb.nil?
    nil
  end
end

class Message < Riddl::Implementation #{{{
  def response
    redis = @a[0]
    cond  = "condition:" + @p[0].value

    uuid = SecureRandom.uuid
    mess = "message:" + @p[0].value
    if @p[2].value.to_i > 0
      redis.setex(mess,@p[2].value.to_i,@p[1].value)
    else
      redis.setex(mess,604800,@p[1].value)
    end

    mdel = false
    if redis.exists?(cond)
      while uuid = redis.lpop(cond)
        SendCallback::send redis.get("value:#{uuid}"), @p[1].value
        del = redis.get("value:del:#{uuid}") == 'true' ? true : false
        mdel = true if del
<<<<<<< HEAD
        redis.multi do |rm|
          rm.del("value:del:#{uuid}")
          rm.del("value:#{uuid}")
          rm.del("value:condition:#{uuid}")
          rm.del("value:ttl:#{uuid}")
=======
        redis.multi do |multi|
          multi.del("value:del:#{uuid}")
          multi.del("value:#{uuid}")
          multi.del("value:condition:#{uuid}")
          multi.del("value:ttl:#{uuid}")
>>>>>>> de3bf82fce9eff686d877d7f3d96c0808a96e6b1
        end
      end
      redis.del(mess) if mdel
    end
  end
end #}}}

Riddl::Server.new(File.join(__dir__,'/message.xml'), :host => 'localhost', :port => 9311) do |opts|
  accessible_description true
  cross_site_xhr true

  opts[:redis] = Redis.new(path: "/tmp/redis.sock", db: 10)

  on resource do
    on resource 'send' do
      run Message, opts[:redis] if post 'message'
    end
    on resource 'receive' do
      run Condition, opts[:redis] if get 'criteria'
      run DeleteCondition, opts[:redis] if delete 'slotid'
    end
  end
end.loop!
