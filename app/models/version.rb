class Version < ActiveRecord::Base
  include Pacecar

  belongs_to :rubygem, :counter_cache => true
  has_many :requirements, :dependent => :destroy
  has_many :dependencies, :dependent => :destroy

  validates_format_of :number, :with => /^[\w\.\-_]+$/

  def validate
    if new_record? && Version.exists?(:rubygem_id => rubygem_id, :number => number, :platform => platform)
      errors.add_to_base("A version already exists with this number or platform.")
    end
  end

  def self.published(limit=5)
    created_at_before(DateTime.now.utc).by_created_at(:desc).limited(limit)
  end

  def to_s
    number
  end

  def to_title
    "#{rubygem.name} (#{to_s})"
  end

  def info
    [ description, summary, "This rubygem does not have a description or summary." ].detect(&:present?)
  end

  def update_attributes_from_gem_specification!(spec)
    self.update_attributes!(
      :authors           => spec.authors.join(', '),
      :description       => spec.description,
      :summary           => spec.summary,
      :rubyforge_project => spec.rubyforge_project,
      :created_at        => spec.date
    )
  end

  def to_index
    [rubygem.name, number, platform]
  end

end
