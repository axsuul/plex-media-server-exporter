FROM ruby:3-alpine3.18

MAINTAINER James Hu <hello@james.hu>

ENV PORT 9594
ENV ROOT /srv
RUN mkdir -p $ROOT

WORKDIR $ROOT

COPY Gemfile $ROOT
COPY Gemfile.lock $ROOT

RUN bundle install

COPY . $ROOT

RUN chmod +x config.ru

CMD bundle exec puma --port $PORT
