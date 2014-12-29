class TorrentsController < InheritedResources::Base
   
  defaults resource_class: Torrent.friendly

  # before_filter :set_feed, except: [:announce, :scrape, :search]

  respond_to :json, :html, :xml, :rss
  prepend_before_filter :set_params_from_torrent, :only => [:create]
  prepend_before_filter :load_from_info_hash

  load_and_authorize_resource :feed
  load_and_authorize_resource :torrent, through: :feed

  skip_before_filter :authenticate_user!, only: [:announce, :scrape, :show, :index]
  # before_filter :authenticate_user!, only: [:]

  layout false


  def announce
    authorize! :announce, resource
    peer = resource.register_peer(peer_params, current_user)

    # This part is standard BitTorrent.
    tracker_response = {
      'interval'    => Peer::UPDATE_PERIOD_MINUTES.minutes,
      'complete'   => resource.seed_count,
      'incomplete' => resource.peer_count,
      'peers'      => resource.peers.active.map{|p|  {'ip' => p.ip, 'peer id' => p.peer_id, 'port' => p.port}}
    }

    # BitTorious-specific extensions.
    if peer.volunteer_enabled
      tracker_response['volunteer'] = {
        affinity_length: peer.affinity_length,
        affinity_offset: peer.affinity_offset
      }
    end

    response.headers['Content-Type'] = 'text/plain; charset=ASCII'
    render :text => tracker_response.to_bencoding.encode('ASCII') # Force US-ASCII
  end

  def create
    @torrent = Torrent.new(torrent_params)
    @torrent.user = current_user
    @torrent.data = request[:torrent][:file].read
    @torrent.feed = Feed.friendly.find(params[:feed_id]) # Must be set prior to metadata reprocessing.
    @torrent.reprocess_meta
    respond_to do |format|
      format.json {
        if @torrent.save
          render json: @torrent, except: [:data]
        else
          render json: {errors: @torrent.errors}, except: [:data], status: :unprocessable_entity
        end
      }
    end
  end

  def index
    # FIXME Shouldn't cancancan do this automatically???
    @torrents = Torrent.where(feed_id: params[:feed_id]).accessible_by(current_ability)

    respond_to do |f|
      f.json { render json: @torrents, include: [{user: {only: [:id, :name]}}], methods: [:seed_count, :peer_count], except: [:data] }
    end    
  end

  def peers
    respond_to do |f|
      f.json { render json: resource.active_peers, include: {user: {only: [:id, :name]}} }
    end
  end

	def scrape
		# From http://wiki.theory.org/BitTorrentSpecification
		#   If info_hash was supplied and was valid, this dictionary will contain a single key/value. Each key consists of a 20-byte binary info_hash. The value of each entry is another dictionary containing the following:
		#
		#   complete: number of peers with the entire file, i.e. seeders (integer)
		#   downloaded: total number of times the tracker has registered a completion ("event=complete", i.e. a client finished downloading the torrent)
		#   incomplete: number of non-seeder peers, aka "leechers" (integer)
		#   name: (optional) the torrent's internal name, as specified by the "name" file in the info section of the .torrent file
		requested = []
		torrents = {}
		if(params[:info_hash] && t = load_from_info_hash)
      authorize! :read, t
			requested << t if t
		else
      requested = Torrent.accessible_by current_ability
			# Torrent.all.each do |t|
   #      requested << t if can?(:read, t)
   #    end
		end
		requested.each do |t|
			torrents[t.info_hash] = {
				complete: t.seed_count,
				#downloaded: t.downloaded,
				incomplete: t.peer_count,
				name: t.name
			}
		end
		render text: {files: torrents}.bencode
	end

  def show
    authorize! :read, @torrent
    respond_to do |format|
      format.json { render json: resource, except: [:data], include: [{user: {only: [:id, :name]}}, :active_peers]}
      format.torrent { send_data(resource.data_for_user(current_user, announce_url))}
      # format.json { render :json => {:id => resource.id, :name => resource.name, :meta_html => render_to_string('_meta_data', :formats => :html, :layout => false, :locals => {:meta_data => resource.tracker.meta_data})}}
    end
  end

  private

  def peer_params
    @peer_params ||= {
      info_hash:   params[:info_hash].unpack('H*').first,
      peer_id:     params[:peer_id].unpack('H*').first,
      remote_ip:   get_remote_ip, 
      uploaded:    params[:uploaded].to_i,
      downloaded:  params[:downloaded].to_i,
      left:        params[:left].to_i,
      key:         params[:key],
      event:       params[:event] || 'started',
      seed:        !!(@left == 0),
      rsize:       rsize,
      port:        params[:port]
    }
  end

  def rsize
    rsize = 50
    ['num want', 'numwant', 'num_want'].each do |k|
      if params[k]
        rsize = params[k].to_i
        break
      end
    end
  end

def set_params_from_torrent
  if !(request.params['torrent']['torrent_file'].blank?)
    torrent_params = request.params['torrent']
    b = 
      if torrent_params['torrent_file'].respond_to?(:path)
        BEncode.load_file(torrent_params['torrent_file'].path)
      else
        b64_file_contents = torrent_params['torrent_file'].read
        #set it back
        torrent_params['torrent_file'].rewind
        BEncode.load(b64_file_contents)
      end
    request.params['torrent']['info_hash'] = Digest::SHA1.hexdigest b["info"].bencode
    if torrent_params['name'].blank? && torrent_params['torrent_file'].respond_to?(:original_filename)
      request.params['torrent']['name'] = torrent_params['torrent_file'].original_filename.gsub(/\.torrent$/,'')
    end
  end
end


  def load_from_info_hash
    @torrent = Torrent.find_by_info_hash(params[:info_hash].unpack('H*').first) if params[:info_hash]
  end


  private


  # Never trust parameters from the scary internet, only allow the white list through.
  def torrent_params
    params.require(:torrent).permit(
      :feed_id, :name) #:user_id, :info_hash, :size, :feed_id, :private_info_hash)

  end

end
