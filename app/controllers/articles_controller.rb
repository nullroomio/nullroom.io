class ArticlesController < ApplicationController
  def index
    @articles = Article.all
  end

  def show
    @article = Article.find(params[:slug]) or raise ActionController::RoutingError, "Not Found"
  end
end
