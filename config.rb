# DSL for wmiirc configuration.
#--
# Copyright 2006 Suraj N. Kurapati
# See the LICENSE file for details.
#++

require 'shellwords'
require 'pathname'
require 'yaml'

require 'rubygems'
gem 'rumai', '~> 3'
require 'rumai'

include Rumai

class Handler < Hash
  def initialize
    super {|h,k| h[k] = [] }
  end

  ##
  # If a block is given, registers a handler
  # for the given key and returns the handler.
  #
  # Otherwise, executes all handlers registered for the given key.
  #
  def handle key, *args, &block
    if block
      self[key] << block

    elsif key? key
      self[key].each do |block|
        block.call(*args)
      end
    end

    block
  end
end

EVENTS  = Handler.new
ACTIONS = Handler.new
KEYS    = Handler.new

##
# When a block is given, registers a handler
# for the given event and returns the handler.
#
# Otherwise, executes all handlers for the given event.
#
def event *a, &b
  EVENTS.handle(*a, &b)
end

##
# Returns a list of registered event names.
#
def events
  EVENTS.keys
end

##
# If a block is given, registers a handler for
# the given action and returns the handler.
#
# Otherwise, executes all handlers for the given action.
#
def action *a, &b
  ACTIONS.handle(*a, &b)
end

##
# Returns a list of registered action names.
#
def actions
  ACTIONS.keys
end

##
# If a block is given, registers a handler for
# the given keypress and returns the handler.
#
# Otherwise, executes all handlers for the given keypress.
#
def key *a, &b
  KEYS.handle(*a, &b)
end

##
# Returns a list of registered action names.
#
def keys
  KEYS.keys
end

##
# Shows a menu (where the user must press keys on their keyboard to
# make a choice) with the given items and returns the chosen item.
#
# If nothing was chosen, then nil is returned.
#
# ==== Parameters
#
# [prompt]
#   Instruction on what the user should enter or choose.
#
def key_menu choices, prompt = nil
  words = %w[dmenu -b -fn].push(CONFIG['display']['font'])

  words.concat %w[-nf -nb -sf -sb].zip(
    [
      CONFIG['display']['color']['normal'],
      CONFIG['display']['color']['focus'],

    ].map {|c| c.to_s.split[0,2] }.flatten

  ).flatten

  words.push '-p', prompt if prompt

  command = words.shelljoin
  IO.popen(command, 'r+') do |menu|
    menu.puts choices
    menu.close_write

    choice = menu.read
    choice unless choice.empty?
  end
end

##
# Shows a menu (where the user must click a menu
# item using their mouse to make a choice) with
# the given items and returns the chosen item.
#
# If nothing was chosen, then nil is returned.
#
# ==== Parameters
#
# [choices]
#   List of choices to display in the menu.
#
# [initial]
#   The choice that should be initially selected.
#
#   If this choice is not included in the list
#   of cohices, then this item will be made
#   into a makeshift title-bar for the menu.
#
def click_menu choices, initial = nil
  words = %w[wmii9menu]

  if initial
    words << '-i'

    unless choices.include? initial
      initial = "<<#{initial}>>:"
      words << initial
    end

    words << initial
  end

  words.concat choices
  command = words.shelljoin

  choice = `#{command}`.chomp
  choice unless choice.empty?
end

##
# Returns the basenames of executable files present in the given directories.
#
def find_programs *dirs
  dirs.flatten.
  map {|d| Pathname.new(d).expand_path.children rescue [] }.flatten.
  map {|f| f.basename.to_s if f.file? and f.executable? }.compact.uniq.sort
end

##
# Launches the command built from the given words in the background.
#
def launch *words
  command = words.shelljoin
  system "#{command} &"
end

##
# A button on a bar.
#
class Button < Thread
  ##
  # Creates a new button at the given node and updates its label
  # according to the given refresh rate (measured in seconds).  The
  # given block is invoked to calculate the label of the button.
  #
  # The return value of the given block can be either an
  # array (whose first item is a wmii color sequence for the
  # button, and the remaining items compose the label of the
  # button) or a string containing the label of the button.
  #
  # If the given block raises a standard exception, then that will be
  # rescued and displayed (using error colors) as the button's label.
  #
  def initialize fs_bar_node, refresh_rate, &button_label
    raise ArgumentError, 'block must be given' unless block_given?
    super(fs_bar_node) do |button|
      while true
        label =
          begin
            Array(button_label.call)
          rescue Exception => e
            LOG.error e
            [CONFIG['display']['color']['error'], e]
          end

        # provide default color
        unless label.first =~ /(?:#[[:xdigit:]]{6} ?){3}/
          label.unshift CONFIG['display']['color']['normal']
        end

        button.create unless button.exist?
        button.write label.join(' ')
        sleep refresh_rate
      end
    end
  end

  ##
  # Refreshes the label of this button.
  #
  alias refresh wakeup
end

##
# Loads the given YAML configuration file.
#
def load_config config_file
  config_data = YAML.load_file(config_file)
  Object.const_set :CONFIG, config_data

  # display
    fo = ENV['WMII_FONT']        = CONFIG['display']['font']
    fc = ENV['WMII_FOCUSCOLORS'] = CONFIG['display']['color']['focus']
    nc = ENV['WMII_NORMCOLORS']  = CONFIG['display']['color']['normal']

    settings = {
      'font'        => fo,
      'focuscolors' => fc,
      'normcolors'  => nc,
      'border'      => CONFIG['display']['border'],
      'bar on'      => CONFIG['display']['bar'],
      'colmode'     => CONFIG['display']['column']['mode'],
      'grabmod'     => CONFIG['control']['grab'],
    }

    fs.ctl.write settings.map {|pair| pair.join(' ') }.join("\n")

    launch 'xsetroot', '-solid', CONFIG['display']['background']

    # column
      fs.colrules.write CONFIG['display']['column']['rule']

    # client
      event 'CreateClient' do |client_id|
        client = Client.new(client_id)

        unless defined? @client_tags_by_regexp
          @client_tags_by_regexp = CONFIG['display']['client'].map {|hash|
            k, v = hash.to_a.first
            [eval(k, TOPLEVEL_BINDING, "#{config_file}:display:client"), v]
          }
        end

        if label = client.props.read rescue nil
          catch :found do
            @client_tags_by_regexp.each do |regexp, tags|
              if label =~ regexp
                client.tags = tags
                throw :found
              end
            end

            # force client onto current view
            client.tags = curr_tag
            client.focus
          end
        end
      end

    # status
      action 'status' do
        fs.rbar.clear

        unless defined? @status_button_by_name
          @status_button_by_name = {}

          CONFIG['display']['status'].each_with_index do |hash, position|
            name, defn = hash.to_a.first

            # buttons are displayed in the ASCII order of their IXP file names
            file = "#{position}-#{name}"

            button = eval(
              "Button.new(fs.rbar[#{file.inspect}], #{defn['refresh']}) { #{defn['content']} }",
              TOPLEVEL_BINDING, "#{config_file}:display:status:#{name}"
            )

            @status_button_by_name[name] = button
          end
        end

        @status_button_by_name.each_value {|b| b.refresh }

      end.call

      ##
      # Refreshes the content of the status button with the given name.
      #
      def status name
        name = name.sub(/^\d+-/,'')

        if button = @status_button_by_name[name]
          button.refresh
        end
      end

  # control
    %w[key action event].each do |param|
      CONFIG['control'][param].each do |name, code|
        eval "#{param}(#{name.inspect}) {|*argv| #{code} }",
             TOPLEVEL_BINDING, "#{config_file}:control:#{param}:#{name}"
      end
    end

  # script
    eval CONFIG['script'], TOPLEVEL_BINDING, "#{config_file}:script"

end

##
# Reloads the entire wmii configuration.
#
def reload_config
  LOG.info 'reload'
  exec $0
end
