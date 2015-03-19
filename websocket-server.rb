require 'em-websocket'
require 'json'
require 'pry'
require 'csv'
require 'time'
$stdout.sync = true

class Client
  attr_accessor :websocket
  attr_accessor :name
  attr_accessor :answered
  attr_accessor :points
  attr_accessor :tta

  def initialize(websocket_arg)
    @websocket = websocket_arg
    @points = 0
    @answered = false
    @tta = {} #time to answer for each question
  end
end

class QuizServer
  MaxNameLength = 10

  attr_accessor :clients

  def initialize
    puts 'starting on port' + ARGV[1]
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
      if (client.name.start_with?('TV'))
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
      send_all JSON.generate({
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

    # Quiz Participant Quits
    elsif (msg.has_key?("quiz_participant_quit"))
      quiz_id = msg["quiz_participant_quit"]["quiz_id"].to_i
      @quiz_participants.each do |_, participants|
        participants.delete(client)
      end

      send_all JSON.generate({
        quiz_participant_quit: {
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
      @quiz_participants[quiz_id].each do |client|
        client.tta[msg["first_question"].to_i] = Time.now.to_i
      end

    # Question Answered
    elsif (msg.has_key?("question_answered"))
      question_id = msg["question_answered"].to_i
      handle_client_answer(client, question_id, msg["answer_id"], msg["correct_answer"])
      quiz_id = msg["quiz_id"].to_i
      unless (client.tta[question_id].nil?) 
        client.tta[question_id] = Time.now.to_i - client.tta[question_id]
      else
        client.tta[question_id] = 15
      end

      send_all_quiz_participants quiz_id, JSON.generate({
        user_answered: client.name,
      })

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
      waiting_time = msg["show_results_timer"] || 5

      if (all_participants_ready(quiz_id))
        sleep waiting_time # seconds

        send_all_quiz_participants quiz_id, JSON.generate({
          new_question_id: msg["next_question"].to_i,
          participants: build_participants_hash(quiz_id),
        })
        @quiz_participants[quiz_id].each do |client|
          client.tta[msg["next_question"].to_i] = Time.now.to_i
        end
      end

    # Finish Quiz
    elsif (msg.has_key?("finish_quiz"))
      client.answered = true
      quiz_id = msg["finish_quiz"].to_i
      waiting_time = msg["show_results_timer"] || 5

      if (all_participants_ready(quiz_id))
        sleep waiting_time # seconds

        send_all_quiz_participants quiz_id, JSON.generate({
          finish_quiz: quiz_id,
          winner_names: get_winner_names(quiz_id),
          participants: build_participants_hash(quiz_id),
        })
        log_quiz_details(quiz_id)
        reset_quiz(quiz_id)
        @quiz_participants[quiz_id] = []
      end
    end
  end

  def log_quiz_details(quiz_id)
    puts 'Writing logfile ...'
    participants = build_participants_hash(quiz_id)
    participants_count = @quiz_participants[quiz_id].length
    avg_score = 0
    avg_tta = 0
    participants.each do |participant|
      participant_tta = 0
      participant[1][:tta].each do |question_id, tta| 
        participant_tta += tta
      end
      participant_tta = participant_tta/participant[1][:tta].length if participant[1][:tta].length > 0
      avg_tta += participant_tta
      avg_score += participant[1][:points]
    end
    if participants_count > 0
      avg_score = avg_score/participants_count
      avg_tta = avg_tta/participants_count
    end

    # Row layout: [time, quiz_id, #participants, average_score, average time to answer, particpants: [name: points, tta], ..]]
    CSV.open("log.csv", "a") do |csv|
      csv << [Time.now, quiz_id, participants_count, avg_score, avg_tta, participants]
    end
    puts 'Done'
  end

  def get_winner_names(quiz_id)
    winner = @clients.values[0]
    @quiz_participants[quiz_id].each do |client|
      winner = client if client.points > winner.points
    end
    winners = []
    @quiz_participants[quiz_id].each do |client|
      winners << client.name if client.points == winner.points
    end
    winners
  end

  def handle_client_answer(client, question_id, answer_id, correct_answer)
    client.answered = true
    unless answer_id.nil?
      @question_answers[question_id] = {} if @question_answers[question_id].nil?
      @question_answers[question_id][answer_id] = 0 if @question_answers[question_id][answer_id].nil?
      @question_answers[question_id][answer_id] += 1
      client.points += 1 if (correct_answer == true)
    end
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
      participants[client.name] = {points: client.points, tta: client.tta}
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
      client.answered = false
      client.points = 0
      client.tta = {}
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
quizserver.start(host: "127.0.0.1", port: ARGV[1])
