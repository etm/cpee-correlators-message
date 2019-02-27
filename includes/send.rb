module Send
  def send(callback,message,delivery="source")
    status, res = Riddl::Client.new(callback).put [
      Riddl::Parameter::Complex.new('message','application/json',JSON.generate({ "message" => message, "delivery" => delivery }))
    ]
  end
end

