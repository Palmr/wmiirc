# Ruby interface to WMII.
=begin
  Copyright 2006 Suraj N. Kurapati
  Copyright 2006 Stephan Maka

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
=end

$:.unshift File.join(File.dirname(__FILE__), 'ruby-ixp', 'lib')
require 'ixp'

require 'find'
require 'singleton'

class Wmii
  include Singleton

  def initialize
    begin
      @cl = IXP::Client.new
    rescue Errno::ECONNREFUSED
      retry
    end
  end

  SELECTION_TAG = 'SEL'

  def select_current_client aToggle = false
    Client.new(self, "/view/sel/sel").with_tags do |tags|
      if aToggle && tags.include?(SELECTION_TAG)
        tags.delete SELECTION_TAG
      else
        tags << SELECTION_TAG
      end
    end
  end

  def select_current_view
    Area.new(self, "/view/sel").each_client do
      select_current_client
    end
  end

  def select_none
    if areaList = read("/#{SELECTION_TAG}")
      areaList.split.grep(/^\d+$/).each do |area|
        read("/#{SELECTION_TAG}/#{area}").split.grep(/^\d+$/).reverse.each do |client|
          Client.new(self, "/#{SELECTION_TAG}/#{area}/#{client}").with_tags do |tags|
            tags.delete SELECTION_TAG
          end
        end
      end
    end
  end

  def with_selection  # :yields: client
  end

  # Creates the given WM path.
  def create aPath
    begin
      @cl.create aPath
    rescue IXP::IXPException => e
      puts "#{e.backtrace.first}: #{e}"
    end
  end

  # Deletes the given WM path.
  def remove aPath
    begin
      @cl.remove aPath
    rescue IXP::IXPException => e
      puts "#{e.backtrace.first}: #{e}"
    end
  end

  # Writes the given content to the given WM path.
  def write aPath, aContent
    begin
      @cl.open(aPath) do |f|
        f.write aContent.to_s
      end
    rescue IXP::IXPException => e
      puts "#{e.backtrace.first}: #{e}"
    end
  end

  # Reads from the given WM path and returns the content. If the path is a directory, then the names of all files in that directory are returned.
  def read aPath
    begin
      @cl.open(aPath) do |f|
        if f.respond_to? :next # read file-names from directory
          names = ''

          while i = f.next
            names << i.name << "\n"
          end

          names
        else # read file contents
          f.read_all
        end
      end
    rescue IXP::IXPException => e
      puts "#{e.backtrace.first}: #{e}"
    end
  end

  # Shows the view with the given name.
  def showView aName
    write '/ctl', "view #{aName}"
  end

  # Shows a WM menu with the given content and returns its output.
  def showMenu aContent
    output = nil

    IO.popen('wmiimenu', 'r+') do |menu|
      menu.write aContent
      menu.close_write

      output = menu.read
    end

    output
  end

  # Shows the client which has the given ID.
  def showClient aClientId
    read('/tags').split.each do |view|
      read("/#{view}").split.grep(/^\d+$/).each do |area|
        read("/#{view}/#{area}").split.grep(/^\d+$/).each do |client|
          if read("/#{view}/#{area}/#{client}/index") == aClientId
            showView view
            write '/view/ctl', "select #{area}"
            write "/view/sel/ctl", "select #{client}"
            return
          end
        end
      end
    end
  end

  DETACHED_TAG = 'status'

  # Detach the currently selected client
  def detachClient
    write '/view/sel/sel/tags', DETACHED_TAG
  end

  # Attach the most recently detached client
  def attachClient
    if areaList = read("/#{DETACHED_TAG}")
      areaList.split.grep(/^\d+$/).reverse.each do |area|
        if client = read("/#{DETACHED_TAG}/#{area}").split.grep(/^\d+$/).last
          write "/#{DETACHED_TAG}/#{area}/#{client}/tags", read('/view/name')
          return
        end
      end
    end
  end

  # Changes the current view to an adjacent one (:left or :right).
  def cycleView aTarget
    tags = read('/tags').split

    curTag = read('/view/name')
    curIndex = tags.index(curTag)

    newIndex =
      case aTarget
        when :right
          curIndex + 1

        when :left
          curIndex - 1

        else
          return

      end % tags.length

    showView tags[newIndex]
  end

  # Renames the given view and sends its clients along for the ride.
  def renameView aOld, aNew
    read('/client').split.each do |id|
      tags = read("/client/#{id}/tags")

      write "/client/#{id}/tags", tags.gsub(aOld, aNew).squeeze('+')
    end
  end

  # Applies wmii-2 style tiling layout to the current view while maintaining the order of clients in the current view. Only the first client in the primary column is kept; all others are evicted to the *top* of the secondary column. Any teritiary, quaternary, etc. columns are squeezed into the *bottom* of the secondary column.
  def applyTilingLayout
    areaList = read('/view').split.grep(/^[^0]\d*$/)

    unless areaList.empty?
      # keep only the first client in zoomed area
        write '/view/2/ctl', 'select 0'

        read('/view/1').split.grep(/^[^0]\d*$/).length.times do |i|
          write '/view/1/1/ctl', 'sendto next'
          write '/view/2/sel/ctl', 'swap up' if i.zero?
        end

        # write '/view/1/mode', 'max'

      # squeeze unzoomed clients into secondary column
        if secondary = read('/view/2')
          write '/view/2/ctl', "select #{secondary.split.grep(/^\d+$/).last}"

          (areaList.length - 2).times do
            read('/view/3').split.grep(/^\d+$/).length.times do
              write '/view/3/0/ctl', 'sendto prev'
            end
          end

          write '/view/2/mode', 'default'
        end
    end
  end

  # Applies wmii-2 style grid layout to the current view while maintaining the order of clients in the current view. If the maximum number of clients per column, the distribution of clients among the columns is calculated according to wmii-2 style. Only the first client in the primary column is kept; all others are evicted to the *top* of the secondary column. Any teritiary, quaternary, etc. columns are squeezed into the *bottom* of the secondary column.
  def applyGridLayout aMaxClientsPerColumn = nil
    # determine client distribution
      unless aMaxClientsPerColumn
        numClients = 0

        read('/view').split.grep(/^[^0]\d*$/).each do |column|
          numClients += read("/view/#{column}").split.grep(/^\d+$/).length
        end

        return if numClients.zero?


        numColumns = Math.sqrt(numClients)
        aMaxClientsPerColumn = (numClients / numColumns).round
      end

    # distribute the clients
      if aMaxClientsPerColumn <= 0
        # squeeze all clients into a single column
          while clientList = read('/view/2')
            numClients = clientList.split.grep(/^\d+$/).length
            numClients.times do
              write '/view/2/0/ctl', 'sendto prev'
            end
          end
      else
        begin
          columnList = read('/view').split.grep(/^[^0]\d*$/)

          columnList.each do |column|
            if clientList = read("/view/#{column}")
              write "/view/#{column}/mode", 'default'	# set *equal* layout for column

              numClients = clientList.split.grep(/^\d+$/).length
              nextColumn = column.to_i + 1

              if numClients > aMaxClientsPerColumn
                # evict excess clients to next column
                  write "/view/#{nextColumn}/ctl", 'select 0'

                  (numClients - aMaxClientsPerColumn).times do |i|
                    write "/view/#{column}/#{aMaxClientsPerColumn}/ctl", 'sendto next'
                    write "/view/#{nextColumn}/sel/ctl", 'swap up' if i.zero?
                  end

              elsif numClients < aMaxClientsPerColumn
                # import clients from next column
                  write "/view/#{column}/ctl", "select #{read("/view/#{column}").split.grep(/^\d+$/).last}"

                  (aMaxClientsPerColumn - numClients).times do
                    write "/view/#{nextColumn}/0/ctl", 'sendto prev'
                  end
              end
            end
          end
        end until columnList.length == read('/view').split.grep(/^[^0]\d*$/).length
      end
  end

  # Returns a list of program names available in the given paths.
  def findPrograms *aPaths
    list = []

    Find.find(*aPaths) do |f|
      if File.executable?(f) && !File.directory?(f)
        list << File.basename(f)
      end
    end

    list.uniq.sort
  end


  class IXPFile
    attr_reader :wm, :path

    def initialize aWmii, aPath
      @wm = aWmii
      @path = aPath
    end
  end

  class Client < IXPFile
    TAG_DELIMITER = "+"

    def tags
      @wm.read("#{@path}/tags").split(TAG_DELIMITER)
    end

    def tags= aTags
      @wm.write "#{@path}/tags", aTags.uniq.join(TAG_DELIMITER)
    end

    def with_tags # :yields: tags
      if block_given?
        t = self.tags
        yield t
        self.tags = t
      end
    end
  end

  class Area < IXPFile
    def clients
      @wm.read(@path).split.grep(/^\d+$/)
    end

    # For each client in this area, focuses the client and invokes the given block.
    def each_client # :yields: Client
      if block_given?
        # go in reverse order to accomodate destructive procedures (client index is relative to area, not globally unique)
        clients.reverse.each do |i|
          @wm.write "#{@path}/ctl", "select #{i}"
          yield Client.new(@wm, "#{@path}/#{i}")
        end
      end
    end
  end

  class View < IXPFile

  end
end