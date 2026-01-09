#!/usr/bin/ruby
#
# This file is part of CPEE-CORRELATORS-MESSAGE.
#
# CPEE-CORRELATORS-MESSAGE is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# CPEE-CORRELATORS-MESSAGE is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
# Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# CPEE-CORRELATORS-MESSAGE (file LICENSE in the main directory). If not, see
# <http://www.gnu.org/licenses/>.

require 'json'
require 'riddl/server'
require 'riddl/client'
require 'securerandom'
require 'redis'
require 'cpee/redis'

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
        redis.multi do |multi|
          multi.del("value:del:#{uuid}")
          multi.del("value:#{uuid}")
          multi.del("value:condition:#{uuid}")
          multi.del("value:ttl:#{uuid}")
        end
      end
      redis.del(mess) if mdel
    end
  end
end #}}}

Riddl::Server.new(File.join(__dir__,'/message.xml'), :host => 'localhost', :port => 9311) do |opts|
  accessible_description true
  cross_site_xhr true

  opts[:frequency] = 1

  ### set redis_cmd to nil if you want to do global
  ### at least redis_path or redis_url and redis_db have to be set if you do global
  opts[:redis_path]                 ||= 'redis.sock' # use e.g. /tmp/redis.sock for global stuff. Look it up in your redis config
  opts[:redis_db]                   ||= 0
  ### optional redis stuff
  opts[:redis_url]                  ||= nil
  opts[:redis_cmd]                  ||= 'redis-server --port 0 --unixsocket #redis_path# --unixsocketperm 600 --pidfile #redis_pid# --dir #redis_db_dir# --dbfilename #redis_db_name# --databases 1 --save 900 1 --save 300 10 --save 60 10000 --rdbcompression yes --daemonize yes'
  opts[:redis_pid]                  ||= 'redis.pid' # use e.g. /var/run/redis.pid if you do global. Look it up in your redis config
  opts[:redis_db_name]              ||= 'redis.rdb' # use e.g. /var/lib/redis.rdb for global stuff. Look it up in your redis config

  CPEE::redis_connect opts, 'Server Main'

  parallel do
    EM.add_periodic_timer(opts[:frequency]) do
      opts[:redis].scan_each(:match => "value:ttl:*") do |key|
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
    end
  end

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
