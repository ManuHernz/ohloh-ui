class ActivityFact < ActiveRecord::Base
  belongs_to :name
  belongs_to :language
  belongs_to :analysis
end
