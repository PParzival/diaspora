#   Copyright (c) 2010, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

require File.join(Rails.root, 'lib/hcard')

class Person < ActiveRecord::Base
  include ROXML
  include Encryptor::Public
  require File.join(Rails.root, 'lib/diaspora/web_socket')
  include Diaspora::Socketable
  include Diaspora::Guid

  xml_attr :diaspora_handle
  xml_attr :url
  xml_attr :profile, :as => Profile
  xml_attr :exported_key

  has_one :profile
  delegate :last_name, :to => :profile

  before_save :downcase_diaspora_handle
  def downcase_diaspora_handle
    diaspora_handle.downcase!
  end

  has_many :contacts #Other people's contacts for this person
  has_many :posts #his own posts

  belongs_to :owner, :class_name => 'User'

  before_destroy :remove_all_traces
  before_validation :clean_url

  validates_presence_of :url, :profile, :serialized_public_key
  validates_uniqueness_of :diaspora_handle, :case_sensitive => false

  scope :searchable, joins(:profile).where(:profiles => {:searchable => true})

  def self.search(query, user)
    return [] if query.to_s.blank?

    where_clause = <<-SQL
      profiles.first_name LIKE ? OR
      profiles.last_name LIKE ? OR
      people.diaspora_handle LIKE ?
    SQL
    sql = ""
    tokens = []

    query_tokens = query.to_s.strip.split(" ")
    query_tokens.each_with_index do |raw_token, i|
      token = "%#{raw_token}%"
      sql << " OR " unless i == 0
      sql << where_clause
      tokens.concat([token, token, token])
    end

    Person.searchable.where(sql, *tokens).includes(:contacts).order("contacts.user_id DESC", "profiles.last_name ASC", "profiles.first_name ASC", "people.diaspora_handle ASC")
  end

  def name
    @name ||= if profile.first_name.nil? || profile.first_name.blank?
                self.diaspora_handle
              else
                "#{profile.first_name.to_s} #{profile.last_name.to_s}"
              end
  end

  def first_name
    @first_name ||= if profile.first_name.nil? || profile.first_name.blank?
                self.diaspora_handle.split('@').first
              else
                profile.first_name.to_s
              end
  end

  def owns?(post)
    self == post.person
  end

  def receive_url
    "#{self.url}receive/users/#{self.guid}/"
  end

  def public_url
    "#{self.url}public/#{self.owner.username}"
  end

  def public_key_hash
    Base64.encode64 OpenSSL::Digest::SHA256.new(self.exported_key).to_s
  end

  def public_key
    OpenSSL::PKey::RSA.new(serialized_public_key)
  end

  def exported_key
    serialized_public_key
  end

  def exported_key= new_key
    raise "Don't change a key" if serialized_public_key
    serialized_public_key = new_key
  end

  #database calls
  def self.by_account_identifier(identifier)
    identifier = identifier.strip.downcase.gsub('acct:', '')
    self.where(:diaspora_handle => identifier).first
  end

  def self.local_by_account_identifier(identifier)
    person = self.by_account_identifier(identifier)
   (person.nil? || person.remote?) ? nil : person
  end

  def self.create_from_webfinger(profile, hcard)
    return nil if profile.nil? || !profile.valid_diaspora_profile?
    new_person = Person.new
    new_person.serialized_public_key = profile.public_key
    new_person.guid = profile.guid
    new_person.diaspora_handle = profile.account
    new_person.url = profile.seed_location

    #hcard_profile = HCard.find profile.hcard.first[:href]
    Rails.logger.info("event=webfinger_marshal valid=#{new_person.valid?} target=#{new_person.diaspora_handle}")
    new_person.url = hcard[:url]
    new_person.profile = Profile.create!(:first_name => hcard[:given_name],
                              :last_name  => hcard[:family_name],
                              :image_url  => hcard[:photo],
                              :image_url_medium  => hcard[:photo_medium],
                              :image_url_small  => hcard[:photo_small],
                              :searchable => hcard[:searchable])
    new_person.save!
    new_person
  end

  def remote?
    owner_id.nil?
  end

  def as_json(opts={})
    {
      :person => {
        :id           => self.guid,
        :name         => self.name,
        :url          => self.url,
        :exported_key => exported_key,
        :diaspora_handle => self.diaspora_handle
      }
    }
  end

  def self.from_post_comment_hash(hash)
    person_ids = hash.values.flatten.map!{|c| c.person_id}.uniq
    people = where(:id => person_ids)
    people_hash = {}
    people.each{|p| people_hash[p.id] = p}
    people_hash
  end

  protected

  def clean_url
    self.url ||= "http://localhost:3000/" if self.class == User
    if self.url
      self.url = 'http://' + self.url unless self.url.match(/https?:\/\//)
      self.url = self.url + '/' if self.url[-1, 1] != '/'
    end
  end

  private
  def remove_all_traces
    Post.where(:person_id => id).delete_all
    Contact.where(:person_id => id).delete_all
    Notification.where(:actor_id => id).delete_all
  end
end
