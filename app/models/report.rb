class Report < ActiveRecord::Base
	
  MAXIMUM_WAIT_TIME = 600 # we will ignore reports > this as they are likely bogus and will throw off our data
  
  validates_presence_of :reporter_id
  validates_uniqueness_of :uniqueid, :scope => :source, :allow_blank => true, :message => 'already processed'
  validates_numericality_of :wait_time, :allow_nil => true, :less_than_or_equal_to => MAXIMUM_WAIT_TIME
  
  attr_accessor :latlon, :tag_string   # virtual field supplied by iphone/android
  
  belongs_to :location
  belongs_to :reporter
  belongs_to :polling_place
  belongs_to :reviewer, :class_name => "User"
  
  has_many :report_tags, :dependent => :destroy
  has_many :tags, :through => :report_tags
  has_many :report_filters, :dependent => :destroy
  has_many :filters, :through => :report_filters

  before_validation :set_source
  before_create :detect_location, :append_tags
  after_save :check_uniqueid
  after_create :assign_tags, :assign_wait_time, :assign_filters, :auto_review
  
  named_scope :with_location, :conditions => 'location_id IS NOT NULL'
  named_scope :with_wait_time, :conditions => 'wait_time IS NOT NULL'
  named_scope :with_rating, :conditions => 'rating IS NOT NULL'
  named_scope :assigned, lambda { |user| 
    { :conditions => ['reviewer_id = ? AND reviewed_at IS NULL AND assigned_at > UTC_TIMESTAMP - INTERVAL 10 MINUTE', user.id],
      :order => 'created_at DESC' }
  }
  # @reports = Report.unassigned.assign(@current_user) &tc...
  named_scope( :unassigned, 
    :limit => 10, 
    :order => 'created_at DESC',
    :conditions => 'reviewed_at IS NULL AND reviewer_id IS NULL OR assigned_at < UTC_TIMESTAMP - INTERVAL 10 MINUTE' 
  ) do
    def assign(reviewer)
      # FIXME: can't we do this more efficiently? a la p-code:
      # self.update_all(reviewer_id=reviewer.id, assigned_at => time.now where id IN (each.collect{r.id}))
      each { |r| r.update_attributes(:reviewer_id => reviewer.id, :assigned_at => Time.now.utc) }
    end
  end

  cattr_accessor :public_fields
  @@public_fields = [:id,:source,:text,:score,:zip,:wait_time,:created_at,:updated_at]

  def name
    self.reporter.name
  end
  
  def dismiss!(user=nil)
    self.dismissed_at = Time.now.utc
    self.reviewer = user if user
    self.reviewed_at = Time.now.utc
    user.update_reports_count! if user
    self.save_with_validation(false)
  end
  
  def confirm!(user=nil)
    self.dismissed_at = nil
    self.reviewer = user if user
    self.reviewed_at = Time.now.utc
    if self.save
      user.update_reports_count! if user
      return true
    else
      return false
    end
  end
  
  def is_confirmed?
    self.dismissed_at.nil? && !self.reviewed_at.nil?
  end
  
  def is_dismissed?
    !self.dismissed_at.nil?
  end
  
  def icon
    self.reporter.icon =~ /http:/ ? self.reporter.icon : "http://votereport.us#{self.reporter.icon}"
  end
    
  alias_method :ar_to_json, :to_json
  def to_json(options = {})
    options[:only] = @@public_fields
    # options[:include] = [ :reporter, :polling_place ]
    # options[:except] = [ ]
    options[:methods] = [ :display_text, :display_html, :rating, :name, :icon, :reporter, :polling_place, :location ].concat(options[:methods]||[]) #lets us include current_items from feeds_controller#show
    # options[:additional] = {:page => options[:page] }
    ar_to_json(options)
  end    

    
  def self.find_with_filters(filters = {})
    conditions = ["",filters]
    if filters.include?(:dtstart) && !filters[:dtstart].blank?
      conditions[0] << "created_at >= :dtstart"
    end
    if filters.include?(:dtend) && !filters[:dtend].blank?
      conditions[0] << "created_at <= :dtend"
    end
    if filters.include?(:wait_time) && !filters[:wait_time].blank?
      conditions[0] << "wait_time IS NOT NULL AND wait_time >= :wait_time"
    end
    if filters.include?(:rating) && !filters[:rating].blank?
      conditions[0] << "rating IS NOT NULL AND rating <= :rating"
    end
    
    if filters.include?(:state) && !filters[:state].blank?
      filtered = Filter.find_by_name(US_STATES[filters[:state]])
      filtered.reports.paginate( :page => filters[:page] || 1, :per_page => filters[per_page] || 10, 
                        :order => 'created_at DESC') if filtered
    else
      # TODO put in logic here for doing filtering by appropriate parameters
      Report.paginate( :page => filters[:page] || 1, :per_page => filters[:per_page] || 10, 
                        :order => 'created_at DESC',
                        :conditions => conditions,
                        :include => [:location, :reporter, :polling_place])
    end
  end
  
  ## cached tags string
  def tag_s
    self[:tag_s]
  end
  
  # updates tag string cache
  def cache_tags
    self[:tag_s] =  self.tags.collect{|tag| tag.pattern}.reject{|p| p.starts_with?('wait') }.sort.join(' ')
  end
  
  # over-ride tag_s accessor to set self.tags from given string
  # where input is just tags, a la "machine challenges good bad"
  def tag_s=(text)
    text ||= "" # coerce nil values to empty strings
    # standardize white-space and strip out the octothorpe
    text = text.strip.gsub(/#/, '') # dont use strip! will return nil if not modified
    new_tags = []
    Tag.find(:all).each do |t|
      if text[/#{t.pattern}/i]
        new_tags << t
      end
    end
    self.tags = new_tags.uniq.compact # exclude any duplicate and nil values 
    self.score = self.tags.inject(0) { |sum, t| sum+t.score }
    self.cache_tags # cache tags string
  end
  
  # Subsititute text for reports that have none
  def display_text
    return self.text unless self.text.blank?
    [wait_time     ? "#{wait_time} minute wait time" : nil,
     rating        ? "rating #{rating}" : nil,
     polling_place ? "polling place: #{polling_place.name}" : nil].compact.join(', ')    
  end
  

  include ActionView::Helpers::DateHelper
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::TagHelper
  def display_html
    html = '<div class="balloon">'

    if self.reporter.class == TwitterReporter
      html << %Q{<a href="#{self.reporter.profile}"><img src=#{self.reporter.icon} class="profile" target="_new"/></a>}
    else
      html << %Q{<br /><img src="#{self.reporter.icon}" class="profile" />}
    end

    html << %Q{<img class="rating_icon" style="clear:left;" src="/images/rating_good.png" />}
    html << %Q{<div class="balloon_body"><span class="author" id="screen_name">#{self.reporter.name}</span>: }
    linked_text = auto_link_urls(self.text, :target => '_new') { |linktext| truncate(linktext, 30) }
    html << %Q{<span class="entry-title">#{linked_text}</span><br />}
    html << [wait_time     ? "#{wait_time} minute wait time" : nil,
     rating        ? "Rating: #{rating}" : nil,
     polling_place ? "Polling place: #{polling_place.name}" : nil].compact.join('<br />')    

    # <!--TODO: make name a link to twitter profile like icon is-->
    # <a href="http://twitter.com/randomdeanna" class="author">Deanna Zandt</a>: <span class="entry-title">made some more changes to 
    # 
    # <!--TODO: make URLs autolink! -->
    # <a href="http://twittervotereport.com">http://twittervotereport.com</a>: added big map, made the tweets look nicer. pretty things! #votereport</span><br /> 
    #   <!--<span class="vcard author" id="screen_name"><%=report.reporter.name%></span>: <span class="entry-title"><%=report.display_text%></span><br /> --> 
    html << "<br /><div class='whenwhere'>"
    if self.reporter.class == TwitterReporter
      html << %Q{reported <a href="http://twitter.com/#{self.reporter.screen_name}/statuses/#{self.uniqueid}">#{ time_ago_in_words(self.created_at)} ago</a> }
    else
      html << "reported #{time_ago_in_words(self.created_at)} ago"
    end
    html << "<br />from #{self.location.address.gsub(/, USA/,'')}"
    html << "<br />via #{self.reporter.source_name}</div></div></div>"

    html
  end
  
  def audio_file
    "#{uniqueid}." + (self.source=='IPH' ? 'caf' : 'gsm')
  end

  private
  def set_source
    self.source = self.reporter.source
  end

  def check_uniqueid
    update_attribute(:uniqueid, "#{Time.now.to_i}.#{self.id}") if self.uniqueid.nil?
  end
  
  # Detect and geocode any location information present in the report text
  def detect_location
    if self.text
      LOCATION_PATTERNS.find { |p| self.text[p] }
      self.location = Location.geocode($1) if $1
      self.zip = location.postal_code if !self.zip && (self.location && location.postal_code)
    end
    if !self.location && self.zip
      self.location = Location.geocode(self.zip)
    end
    self.location = self.reporter.location if !self.location && self.reporter && self.reporter.location
    ll, self.location_accuracy = self.latlon.split(/:/) if self.latlon
    true
  end
  
  # append tag_string to report text if supplied (iphone, android)
  def append_tags
    self.text += (" "+self.tag_string) if !self.tag_string.blank?
    true
  end
  
  # What tags are associated with this report?
  # Find them and store for easy reference later
  def assign_tags
    if self.text
      self.tag_s = self.text.scan(/\s+\#\S+/).join(' ')
    end
    true
  end
  
  def assign_wait_time
    return unless self.text
    
    case self.text
    when /wait(\d{1,4})/     # waitNUM
      self.wait_time = $1
    when /wait:(\d{1,4})/    # wait:NUM
      self.wait_time = $1
    when /wait\s+(\d{1,4})/  # wait NUM
      self.wait_time = $1
    when /\s(\d)(\s+|\-)hours?/      # NUM hour(s) or NUM-hour(s)
      self.wait_time = $1.to_i * 60 
    when /\s(\d{1,4})(\s+|\-)minutes?/   # NUM minute(s) or NUM-minute(s)
      self.wait_time = $1
    end
    
    if self.wait_time && self.wait_time > MAXIMUM_WAIT_TIME
      # TODO : flag this report for special review
      self.wait_time = MAXIMUM_WAIT_TIME
    end
  end
  
  # What location filters apply to this report?  US, MD, etc?
  def assign_filters
    if self.location_id && self.location.filter_list
			values = self.location.filter_list.split(',').map { |f| "(#{f},#{self.id})" }.join(',')
      self.connection.execute("INSERT DELAYED INTO report_filters (filter_id,report_id) VALUES #{values}") if !values.blank?
		end
		true
  end
  
  def auto_review
    if self.wait_time && self.location
      self.reviewed_at = Time.now.utc
    end
    true
  end
end
