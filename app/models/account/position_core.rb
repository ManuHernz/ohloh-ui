class Account::PositionCore < OhDelegator::Base
  parent_scope do
    has_many :positions, -> { where { project_id.eq(nil) | project_id.not_in(Project.deleted) } }
    # FIXME: Replace account.has_claimed_positions? with account.claimed_positions.any?
    has_many :claimed_positions, -> { where { name_id.not_eq(nil) } }, class_name: :Position
  end

  # FIXME: Replace positions.for_ohloh_projects with position_core.with_projects
  def with_projects
    @positions_with_projects ||=
      positions.includes(:project).where { positions.project_id.not_eq(nil) }.order { lower(projects.name).asc }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  # FIXME: Replace ordered_positions with position_core.ordered
  def ordered
    preloaded_positions.sort do |position_a, position_b|
      position_a_name_fact = name_facts["#{ position_a.project.best_analysis_id }_#{ position_a.name_id }"].try(:first)
      position_b_name_fact = name_facts["#{ position_b.project.best_analysis_id }_#{ position_b.name_id }"].try(:first)

      retval = 0
      if position_a_name_fact && position_b_name_fact
        retval = position_a_name_fact <=> position_b_name_fact
      end
      (retval == 0) ? (position_a.project.name.to_s <=> position_b.project.name.to_s) : retval
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # FIXME: Replace positions_name_facts with position_core.name_facts
  # Returns a mapping of (position.project.analysis_id)_(position.name_id) => [position.name_fact] for all positions.
  def name_facts
    return @name_facts if @name_facts
    # Using preloaded_positions.pluck(:best_analysis_id) will trigger a new sql query.
    analysis_ids = preloaded_positions.map { |position| position.project.best_analysis_id }.compact
    name_ids = preloaded_positions.map(&:name_id).compact

    name_facts = NameFact.where(analysis_id: analysis_ids, name_id: name_ids)
    @name_facts = name_facts.group_by do |name_fact|
      # Form unique groups
      "#{ name_fact.analysis_id }_#{ name_fact.name_id }"
    end
  end

  # FIXME: Replace ensure_position_or_alias! with position_core.ensure_position_or_alias!
  # claim a position if there is no existing position for the project or create an alias
  def ensure_position_or_alias!(project, name, try_create = false, position_attributes = {})
    existing_position = project.positions.claimed_by(account).first
    return unless existing_position || try_create

    Account.transaction do
      if existing_position && project.best_analysis && project.best_analysis.name_fact_for(existing_position.name_id)
        create_alias(project, name, existing_position, position_attributes)
      else
        attributes = position_attributes.merge(account: account, project: project, committer_name: name.name)
        recreate_position(existing_position, attributes)
      end
    end
  end

  # FIXME: Replace account.positions_logos with account.position_core.logos
  def logos
    logo_ids = preloaded_positions.map { |position| position.project.logo_id }.compact
    @logos ||= Logo.find(logo_ids).index_by(&:id)
  end

  class << self
    # FIXME: Replace account.only_unclaimed_positions account.position_core.with_only_unclaimed
    def with_only_unclaimed
      Account.where('id in (select account_id from positions group by account_id having max(name_id) IS NULL)')
    end
  end

  private

  def create_alias(project, name, existing_position, position_attributes)
    # Augment the existing, valid position by creating an alias that merges the old and new names.
    project.create_alias(name.id, existing_position.name_id, true).tap do
      # and update the existing position to use new position_attributes(title, desc)
      existing_position.update_attributes!(position_attributes)
    end
  end

  def recreate_position(existing_position, attributes)
    # User may already have a position and its name could be missing (from a deleted CVS repository, probably).
    # In that case, let's delete the existing position, and create a new one.
    existing_position.try(:destroy)
    # If no existing position, then create a new one including the form attributes(title, desc)
    # TODO: Consider removing committer_name=.
    Position.create!(attributes)
  end

  def preloaded_positions
    @preloaded_positions ||= positions.includes({ project: [:best_analysis, :organization] }, :name, :contribution)
  end
end