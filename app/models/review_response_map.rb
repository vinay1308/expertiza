class ReviewResponseMap < ResponseMap
  belongs_to :reviewee, class_name: 'Team', foreign_key: 'reviewee_id'
  belongs_to :contributor, class_name: 'Team', foreign_key: 'reviewee_id'
  belongs_to :assignment, class_name: 'Assignment', foreign_key: 'reviewed_object_id'

  # In if this assignment uses "varying rubrics" feature, the sls
  # "used_in_round" field should not be nil
  # so find the round # based on current time and the due date times, and use that round # to find corresponding questionnaire_id from assignment_questionnaires table
  # otherwise this assignment does not use the "varying rubrics", so in assignment_questionnaires table there should
  # be only 1 questionnaire with type 'ReviewQuestionnaire'.    -Yang
  def questionnaire(round)
    if self.assignment.varying_rubrics_by_round?
      Questionnaire.find(self.assignment.review_questionnaire_id(round))
    else
      Questionnaire.find(self.assignment.review_questionnaire_id)
    end
  end

  def get_title
    "Review"
  end

  def delete(force = nil)
    fmaps = FeedbackResponseMap.where(reviewed_object_id: self.response.response_id)
    fmaps.each {|fmap| fmap.delete(true) }
    maps = MetareviewResponseMap.where(reviewed_object_id: self.id)
    maps.each {|map| map.delete(force) }
    self.destroy
  end

  def self.export_fields(_options)
    fields = ["contributor", "reviewed by"]
    fields
  end

  def self.export(csv, parent_id, _options)
    mappings = where(reviewed_object_id: parent_id)
    mappings.sort! {|a, b| a.reviewee.name <=> b.reviewee.name }
    mappings.each do |map|
      csv << [
        map.reviewee.name,
        map.reviewer.name
      ]
    end
  end

  def self.import(row, _session, id)
    raise ArgumentError, "Not enough items." if row.length < 2

    assignment = Assignment.find(id)
    if assignment.nil?
      raise ImportError, "The assignment with id \"#{id}\" was not found. <a href='/assignment/new'>Create</a> this assignment?"
    end
    index = 1
    while index < row.length
      user = User.find_by_name(row[index].to_s.strip)
      if user.nil?
        raise ImportError, "The user account for the reviewer \"#{row[index]}\" was not found. <a href='/users/new'>Create</a> this user?"
      end
      reviewer = AssignmentParticipant.where(user_id: user.id, parent_id:  assignment.id).first
      if reviewer.nil?
        raise ImportError, "The reviewer \"#{row[index]}\" is not a participant in this assignment. <a href='/users/new'>Register</a> this user as a participant?"
      end
      if assignment.team_assignment
        reviewee = AssignmentTeam.where(name: row[0].to_s.strip, parent_id:  assignment.id).first
        if reviewee.nil?
          raise ImportError, "The author \"#{row[0].to_s.strip}\" was not found. <a href='/users/new'>Create</a> this user?"
        end
        existing = ReviewResponseMap.where(reviewee_id: reviewee.id, reviewer_id:  reviewer.id).first
        if existing.nil?
          ReviewResponseMap.create(reviewer_id: reviewer.id, reviewee_id: reviewee.id, reviewed_object_id: assignment.id)
        end
      else
        puser = User.find_by_name(row[0].to_s.strip)
        if user.nil?
          raise ImportError, "The user account for the reviewee \"#{row[0]}\" was not found. <a href='/users/new'>Create</a> this user?"
        end
        reviewee = AssignmentParticipant.where(user_id: puser.id, parent_id:  assignment.id).first
        if reviewee.nil?
          raise ImportError, "The author \"#{row[0].to_s.strip}\" was not found. <a href='/users/new'>Create</a> this user?"
        end
        team_id = TeamsUser.team_id(reviewee.parent_id, reviewee.user_id)
        existing = ReviewResponseMap.where(reviewee_id: team_id, reviewer_id:  reviewer.id).first
        if existing.nil?
          ReviewResponseMap.create(reviewee_id: team_id, reviewer_id: reviewer.id, reviewed_object_id: assignment.id)
        end
      end
      index += 1
    end
  end

  def show_feedback(response)
    if !self.response.empty? && response
      map = FeedbackResponseMap.find_by_reviewed_object_id(response.id)
      return map.response.last.display_as_html if map and !map.response.empty?
    end
  end

  # This method adds a new entry in the ResponseMap
  def self.add_reviewer(contributor_id, reviewer_id, assignment_id)
    if where(reviewee_id: contributor_id, reviewer_id: reviewer_id).count > 0
      create(reviewee_id: contributor_id,
             reviewer_id: reviewer_id,
             reviewed_object_id: assignment_id)
    else
      raise "The reviewer, \"" + reviewer.name + "\", is already assigned to this contributor."
    end
  end

  def metareview_response_maps
    responses = Response.where(map_id: self.id)
    metareview_list = []
    responses.each do |response|
      metareview_response_maps = MetareviewResponseMap.where(reviewed_object_id: response.id)
      metareview_response_maps.each do |metareview_response_map|
        metareview_list << metareview_response_map
      end
    end
    metareview_list
  end

  # return  the responses for specified round, for varying rubric feature -Yang
  def self.get_assessments_round_for(team, round)
    team_id = team.id
    responses = []
    if team_id
      maps = ResponseMap.where(reviewee_id: team_id, type: "ReviewResponseMap")
      maps.each do |map|
        if !map.response.empty? && !map.response.reject {|r| (r.round != round || !r.is_submitted) }.empty?
          responses << map.response.reject {|r| (r.round != round || !r.is_submitted) }.last
        end
      end
      responses.sort! {|a, b| a.map.reviewer.fullname <=> b.map.reviewer.fullname }
    end
    responses
  end

  # wrap lastest version of responses in each response map, together withe the questionnaire_id
  # will be used to display the reviewer summary
  def self.final_versions_from_reviewer(reviewer_id)
    maps = ReviewResponseMap.where(reviewer_id: reviewer_id)
    assignment = Assignment.find(Participant.find(reviewer_id).parent_id)
    review_final_versions = {}

    if !assignment.varying_rubrics_by_round?
      # same review rubric used in multiple rounds
      review_final_versions[:review] = {}
      review_final_versions[:review][:questionnaire_id] = assignment.review_questionnaire_id
      response_ids = []

      maps.each do |map|
        responses = Response.where(map_id: map.id)
        response_ids << responses.last.id unless responses.empty?
      end
      review_final_versions[:review][:response_ids] = response_ids

    else
      # vary rubric by round
      rounds_num = assignment.rounds_of_reviews

      for round in 1..rounds_num
        symbol = ("review round" + round.to_s).to_sym
        review_final_versions[symbol] = {}
        review_final_versions[symbol][:questionnaire_id] = assignment.review_questionnaire_id(round)
        response_ids = []

        maps.each do |map|
          responses = Response.where(map_id: map.id, round: round)
          response_ids << responses.last.id unless responses.empty?
        end
        review_final_versions[symbol][:response_ids] = response_ids
      end

    end
    review_final_versions
  end

  def self.review_response_report(id, assignment, type, review_user)
    if review_user.nil?
      # This is not a search, so find all reviewers for this assignment
      response_maps_with_distinct_participant_id = ResponseMap.select("DISTINCT reviewer_id").where(["reviewed_object_id = ? and type = ? and calibrate_to = ?", id, type, 0])
      @reviewers = []
      response_maps_with_distinct_participant_id.each do |reviewer_id_from_response_map|
        @reviewers << AssignmentParticipant.find(reviewer_id_from_response_map.reviewer_id)
      end
      @reviewers = Participant.sort_by_name(@reviewers)
    else
      # This is a search, so find reviewers by user's full name
      user = User.select("DISTINCT id").where(["fullname LIKE ?", '%' + review_user[:fullname] + '%'])
      @reviewers = AssignmentParticipant.where(["user_id IN (?) and parent_id = ?", user, assignment.id])
    end
    #  @review_scores[reveiwer_id][reviewee_id] = score for assignments not using vary_rubric_by_rounds feature
    # @review_scores[reviewer_id][round][reviewee_id] = score for assignments using vary_rubric_by_rounds feature
  end

  def email(defn, participant, assignment)
    defn[:body][:type] = "Peer Review"
    AssignmentTeam.find(reviewee_id).users.each do |user|
      defn[:body][:obj_name] = assignment.name
      defn[:body][:first_name] = User.find(user.id).fullname
      defn[:to] = User.find(user.id).email
      Mailer.sync_message(defn).deliver_now
    end
  end
end
