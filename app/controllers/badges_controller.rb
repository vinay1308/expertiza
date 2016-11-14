class BadgesController < ApplicationController

	helper_method :current_user_session, :current_user, :current_user_role?
  	protect_from_forgery with: :exception
  	before_action :set_time_zone
  	before_action :authorize

	def action_allowed?
    	case params[:action]
    	when 'list'
      		current_role_name.eql? 'Student'
     	end
  	end

	
	def list
	end

end