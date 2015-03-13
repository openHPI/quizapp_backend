require 'em-websocket'
require 'json'
require 'pry'

class Client
  attr_accessor :websocket
  attr_accessor :name
  attr_accessor :answered
  attr_accessor :points

  def initialize(websocket_arg)
    @websocket = websocket_arg
    @points = 0
    @answered = false
  end
end

class QuizServer
  MaxNameLength = 10

  attr_accessor :clients

  def initialize
    @clients = {}
    @quiz_participants = {}
    @tv_clients = {}
    @question_answers = {}
  end

  def start(opts={})
    puts "QuizServer online"

    EventMachine::WebSocket.start(opts) do |websocket|
      websocket.onopen    { add_client(websocket) }
      websocket.onmessage { |msg| handle_message(websocket, msg) }
      websocket.onclose   { remove_client(websocket) }
    end
  end

  def add_client(websocket)
    client = Client.new(websocket)
    client.name = assign_name('')
    @clients[websocket] = client
    puts "New Client connected: #{client.name}"
    puts "Active clients: #{client_names.join(",")}"
  end

  def remove_client(websocket)
    client = @clients.delete(websocket)
    @quiz_participants.each do |_, participants|
      participants.delete(client)
    end

    send_all JSON.generate({
      disconnected_client: client.name,
    })
    puts "Active clients: #{client_names.join(",")}"
  end

  # Sends a message to all clients
  def send_all(message)
    @clients.each do |websocket, client|
      websocket.send message
    end
    puts "send_all: #{message}"
  end

  # Sends a message to all quiz_participants
  def send_all_quiz_participants(quiz_id, message)
    @clients.each do |websocket, client|
      if (@quiz_participants[quiz_id].include?(client) || @tv_clients.include?(websocket))
        websocket.send message
      end
    end
    puts "send_all_participants of quiz #{quiz_id}: #{message}"
  end

  # Handle a message received from a websocket
  def handle_message(ws, msg)
    puts "Received message: #{msg}"
    msg = JSON.parse(msg)
    client = @clients[ws]

    # New User 
    if (msg.has_key?("new_user"))
      client.name = assign_name(msg['new_user'])
      if (client.name == 'TV')
        @tv_clients[ws] = client
        ws.send JSON.generate({
          tv_client: client.name,
        })
        puts 'TV connected'
      else
        send_all "New user: #{client.name}!".to_json
        ws.send "Welcome on the server #{client.name}!".to_json
        ws.send "All users: #{client_names.join(",")}".to_json
        ws.send JSON.generate({
          client_name: client.name,
          all_participants: build_all_participants_hash
        })
      end

    # User Logout
    elsif (msg.has_key?("user_logout"))
      @quiz_participants.each do |_, participants|
        participants.delete(client)
      end
      ws.send JSON.generate({
        disconnected_client: client.name,
      })

    # New Quiz Participant 
    elsif (msg.has_key?("new_quiz_participant"))
      quiz_id = msg["new_quiz_participant"]["quiz_id"].to_i
      @quiz_participants[quiz_id] = [] if @quiz_participants[quiz_id].nil?
      @quiz_participants[quiz_id] << client

      send_all JSON.generate({
        new_quiz_participant: {
          user_name: client.name,
          quiz_id: quiz_id,
        }
      })

    # Start Quiz 
    elsif (msg.has_key?("start_quiz"))
      quiz_id = msg["start_quiz"].to_i
      reset_quiz(quiz_id)

      send_all_quiz_participants quiz_id, JSON.generate({
        start_quiz: quiz_id
      })

    # Question Answered
    elsif (msg.has_key?("question_answered"))
      question_id = msg["question_answered"].to_i
      handle_client_answer(client, question_id, msg["answer_id"], msg["correct_answer"])
      quiz_id = msg["quiz_id"].to_i

      if (all_participants_ready(quiz_id))
        send_all_quiz_participants quiz_id, JSON.generate({
          finish_question:  question_id,
          question_answers:  @question_answers[question_id],
          participants: build_participants_hash(quiz_id),
        })
      end

    # Next Question
    elsif (msg.has_key?("next_question"))
      client.answered = true
      quiz_id = msg["quiz_id"].to_i

      if (all_participants_ready(quiz_id))
        sleep 10 # seconds

        send_all_quiz_participants quiz_id, JSON.generate({
          new_question_id: msg["next_question"].to_i,
          participants: build_participants_hash(quiz_id),
        })
      end

    # Finish Quiz
    elsif (msg.has_key?("finish_quiz"))
      client.answered = true
      quiz_id = msg["finish_quiz"].to_i

      if (all_participants_ready(quiz_id))
        sleep 10 # seconds

        send_all_quiz_participants quiz_id, JSON.generate({
          finish_quiz: quiz_id,
          winner_name: get_winner_name,
          participants: build_participants_hash(quiz_id),
        })
        reset_quiz(quiz_id)
        @quiz_participants[quiz_id] = []
      end
    end
  end

  def get_winner_name
    winner = @clients.values[0]
    @clients.values.each do |client|
      winner = client if client.points > winner.points
    end
    winner.name
  end

  def handle_client_answer(client, question_id, answer_id, correct_answer)
    client.answered = true
    @question_answers[question_id] = {} if @question_answers[question_id].nil?
    @question_answers[question_id][answer_id] = 0 if @question_answers[question_id][answer_id].nil?
    @question_answers[question_id][answer_id] += 1
    client.points += 1 if (correct_answer == true)
  end

  def all_participants_ready(quiz_id)
    ready = true
    @quiz_participants[quiz_id].each do |client|
      ready = false unless client.answered
    end
    ready
  end

  def build_participants_hash(quiz_id)
    participants = {}
    @quiz_participants[quiz_id].each do |client|
      client.answered = false
      participants[client.name] = {points: client.points}
    end
    participants
  end

  def build_all_participants_hash
    all_participants = {}
    @quiz_participants.each do |quiz_id, clients|
      all_participants[quiz_id] = build_participants_hash(quiz_id)
    end
    all_participants
  end

  def reset_quiz(quiz_id)
    @question_answers = {}
    @quiz_participants[quiz_id].each do |client|
      client.points = 0 
    end
  end

  def client_names
    @clients.collect{|websocket, c| c.name}.sort
  end

  def sanitize_user_name(raw_name)
    name = raw_name.to_s.scan(/[[:alnum:]]/).join[0,MaxNameLength]
    name.empty? ? "Guest" : name
  end

  def assign_name(requested_name)
    name = sanitize_user_name(requested_name)
    existing_names = self.client_names
    if existing_names.include?(name)
      i = 2
      while existing_names.include?(name + i.to_s)
        i += 1
      end
      name += i.to_s
    end
    return name
  end
end

quizserver = QuizServer.new
quizserver.start(host: "127.0.0.1", port: 8080)
