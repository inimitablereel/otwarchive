class Series < ActiveRecord::Base
  has_many :serial_works, :dependent => :destroy
  has_many :works, :through => :serial_works
  has_many :work_tags, :through => :works, :uniq => true, :source => :tags
  has_many :work_pseuds, :through => :works, :uniq => true, :source => :pseuds

  has_many :taggings, :as => :taggable, :dependent => :destroy
  has_many :tags, :through => :taggings, :source => :tagger, :source_type => 'Tag'
  has_bookmarks
  has_many :user_tags, :through => :bookmarks, :source => :tags

  has_many :creatorships, :as => :creation
  has_many :pseuds, :through => :creatorships
  has_many :users, :through => :pseuds, :uniq => true
  
  validates_presence_of :title
  validates_length_of :title, 
    :minimum => ArchiveConfig.TITLE_MIN, 
    :too_short=> t('title_too_short', :default => "must be at least {{min}} letters long.", :min => ArchiveConfig.TITLE_MIN)

  validates_length_of :title, 
    :maximum => ArchiveConfig.TITLE_MAX, 
    :too_long=> t('title_too_long', :default => "must be less than {{max}} letters long.", :max => ArchiveConfig.TITLE_MAX)
    
  validates_length_of :summary, 
    :allow_blank => true, 
    :maximum => ArchiveConfig.SUMMARY_MAX, 
    :too_long => t('summary_too_long', :default => "must be less than {{max}} letters long.", :max => ArchiveConfig.SUMMARY_MAX)
    
  validates_length_of :notes, 
    :allow_blank => true, 
    :maximum => ArchiveConfig.NOTES_MAX, 
    :too_long => t('notes_too_long', :default => "must be less than {{max}} letters long.", :max => ArchiveConfig.NOTES_MAX)

  attr_accessor :authors
  attr_accessor :toremove
  
  named_scope :visible_logged_in, {:conditions => {:hidden_by_admin => false}, :order => 'updated_at DESC'}
  named_scope :visible_to_public, {:conditions => {:hidden_by_admin => false, :restricted => false}, :order => 'updated_at DESC'}
  
  #TODO: figure out why select distinct gets clobbered
  named_scope :exclude_anonymous, {
    :select => "DISTINCT series.*, MAX(collection_items.anonymous) AS anon, MAX(collection_items.unrevealed) AS unrevealed",
    :joins => "INNER JOIN `serial_works` ON (`series`.`id` = `serial_works`.`series_id`) 
    INNER JOIN `works` ON (`works`.`id` = `serial_works`.`work_id`) 
    LEFT JOIN `collection_items` ON `collection_items`.item_id = `works`.id AND `collection_items`.item_type = 'Work'",
    :group => "series.id",
    :having => "(anon IS NULL OR anon = 0) AND (unrevealed IS NULL OR unrevealed = 0)"}
  
  # Needed to keep the normal pseud.series association from eating the exclude_anonymous selects  
  named_scope :for_pseuds, lambda {|pseuds|
    {:joins => "INNER JOIN creatorships ON (series.id = creatorships.creation_id AND creatorships.creation_type = 'Series')",
    :conditions => ["creatorships.pseud_id IN (?)", pseuds.collect(&:id)]}   
  }
  
 
  def posted_works
    self.works.posted
  end
  
  # visibility aped from the work model
  def visible(current_user=User.current_user)
    if current_user.is_a?(Admin) || (current_user.is_a?(User) && current_user.is_author_of?(self))
      return self
    elsif current_user == :false || !current_user
      return self unless self.restricted || self.hidden_by_admin
    elsif (!self.hidden_by_admin && !self.posted_works.empty?)
      return self
    end
  end

  def visible?(user=User.current_user)
    self.visible(user) == self
  end
  
  def visible_work_count
    if User.current_user == :false
      self.works.posted.unrestricted.count      
    else
      self.works.posted.count
    end 
  end
  
  def visible_word_count
    if User.current_user == :false
      works = self.works.posted.unrestricted.find(:all, :select => "works.word_count")
    else
      works = self.works.posted.find(:all, :select => "works.word_count")
    end
    works.collect(&:word_count).sum
  end
  
  def anonymous?
    !self.works.select { |work| work.anonymous? }.empty?    
  end
	
  def unrevealed?
    !self.works.select { |work| work.unrevealed? }.empty?    
  end
  
	# if the series includes an unrestricted work, restricted should be false
	# if the series includes no unrestricted works, restricted should be true
	def adjust_restricted
		unless self.restricted == !self.works.collect(&:restricted).include?(false)
		  self.toggle!(:restricted)
		end
	end
	
	# Change the positions of the serial works in the series
	def reorder(positions)
	  SortableList.new(self.serial_works.in_order).reorder_list(positions)
	end
  
  # return list of pseuds on this series
  def allpseuds
    works.collect(&:pseuds).flatten.compact.uniq.sort
  end
  
  # return list of users on this series
  def owners
    self.authors.collect(&:user)
  end

  # Virtual attribute for pseuds
  def author_attributes=(attributes)
    self.authors ||= []
    wanted_ids = attributes[:ids]
    wanted_ids.each { |id| self.authors << Pseud.find(id) }
    # if current user has selected different pseuds
    current_user = User.current_user
    if current_user.is_a? User
      self.toremove = current_user.pseuds - wanted_ids.collect {|id| Pseud.find(id)}
    end
    attributes[:ambiguous_pseuds].each { |id| self.authors << Pseud.find(id) } if attributes[:ambiguous_pseuds]
    if attributes[:byline]
      results = Pseud.parse_bylines(attributes[:byline])
      self.authors << results[:pseuds]
      self.invalid_pseuds = results[:invalid_pseuds]
      self.ambiguous_pseuds = results[:ambiguous_pseuds] 
    end
    self.authors.flatten!
    self.authors.uniq!
  end
  
  # Remove a user as an author of this series
  def remove_author(author_to_remove)
    pseuds_with_author_removed = self.pseuds - author_to_remove.pseuds
    raise Exception.new("Sorry, we can't remove all authors of a series.") if pseuds_with_author_removed.empty?
    Series.transaction do
      self.pseuds = pseuds_with_author_removed
      authored_works_in_series = (author_to_remove.works & self.works)
      authored_works_in_series.each do |work|
        work.remove_author(author_to_remove)
      end
    end
  end
  
  # returns list of fandoms on this series
  def allfandoms
    works.collect(&:fandoms).flatten.compact.uniq.sort
  end
  
  def author_tags
    self.work_tags.select{|t| t.type == "Relationship"}.sort + self.work_tags.select{|t| t.type == "Character"}.sort + self.work_tags.select{|t| t.type == "Freeform"}.sort
  end
  
  def tag_groups
    self.work_tags.group_by { |t| t.type.to_s }
  end
  
  # Grabs the earliest published_at date of the visible works in the series
  def published_at
    if self.works.visible.posted.blank?
      self.created_at
    else
      self.works.visible.collect(&:published_at).compact.uniq.sort.first
    end
  end
  
  def revised_at
    if self.works.visible.posted.blank?
      self.updated_at   
    else
      self.works.visible.collect(&:revised_at).compact.uniq.sort.last
    end
  end
end
