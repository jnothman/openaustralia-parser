require 'RMagick'
require 'mechanize_proxy'

require 'configuration'
require 'name'
require 'hpricot'

# TODO: Rename class
class PeopleImageDownloader
  @@SMALL_THUMBNAIL_WIDTH = 44
  @@SMALL_THUMBNAIL_HEIGHT = 59

  def initialize
    # Required to workaround long viewstates generated by .NET (whatever that means)
    # See http://code.whytheluckystiff.net/hpricot/ticket/13
    Hpricot.buffer_size = 262144

    @conf = Configuration.new
    @agent = MechanizeProxy.new
    @agent.cache_subdirectory = "member_images"
  end

  def download(people, small_image_dir, large_image_dir)
    # Sort all the people by last name
    sorted_people = people.sort {|a, b| a.name.last <=> b.name.last}

    sorted_people.each do |person|
      page = person_bio_page(person)
      next unless page
      image = extract_image(page)
      
      if image.nil?
        puts "WARNING: Can't find photo for #{person.name.full_name}"
      elsif extract_name(page)
        image.resize_to_fit(@@SMALL_THUMBNAIL_WIDTH, @@SMALL_THUMBNAIL_HEIGHT).write(small_image_dir + "/#{person.id_count}.jpg")
        image.resize_to_fit(@@SMALL_THUMBNAIL_WIDTH * 2, @@SMALL_THUMBNAIL_HEIGHT * 2).write(large_image_dir + "/#{person.id_count}.jpg")
      else
        puts "WARNING: Couldn't find name on page"
      end
    end
  end

  # Returns nil if page can't be found
  def biography_page_for_person_with_name(text)
    url = "http://parlinfo.aph.gov.au/parlInfo/search/display/display.w3p;query=Dataset:allmps%20" + text.gsub(' ', '%20')
    page = @agent.get(url)
    # Check if the returned page is a valid one. If not just ignore it
    tag1 = page.at('div#content')
    tag2 = page.at('div#content div.error')
    unless (tag2 && tag2.inner_text =~ /There was an unexpected error while processing your request./) ||
      (tag1 && tag1.inner_html =~ /No results found/)
      page
    end
  end
  
  def person_bio_page(person)
    # Each person can be looked up with a query like this:
    # http://parlinfo.aph.gov.au/parlInfo/search/display/display.w3p;query=Dataset:allmps%20John%20Smith
    # Find all the unique variants of the name without any of the titles
    name_variants = person.all_names.map do |n|
      Name.new(:first => n.first, :middle => n.middle, :last => n.last).full_name
    end.uniq
    name_variants_no_middle_name = person.all_names.map do |n|
      Name.new(:first => n.first, :last => n.last).full_name
    end.uniq
    # Check each variant of a person's name and return the biography page for the first one that exists
    matching_name = name_variants.find {|n| biography_page_for_person_with_name(n)}
    if matching_name.nil?
      matching_name = name_variants_no_middle_name.find {|n| biography_page_for_person_with_name(n)}
    end
    page = biography_page_for_person_with_name(matching_name) if matching_name
    if page.nil?
      puts "WARNING: No biography page found for #{name_variants.join(' or ')}"
    else
      puts "Found biography page for #{person.name.full_name}"
      page
    end
  end

  def extract_name(page)
    title = strip_tags(extract_metadata_tags(page)["Title"])
    if title =~ /^(Biography for )?(.*)$/
      Name.last_title_first($~[2])
    else
      throw "Unexpected form for title of biography page: #{title}"
    end
  end
  
  # Returns an array of values for the metadata
  def raw_metadata(page)
    labels = page.search('dt.mdLabel')
    values = page.search('dd.mdValue')
    throw "Number of values do not match number of labels" if labels.size != values.size
    metadata = {}
    (0..labels.size-1).each do |index|
      label = labels[index].inner_html
      value = values[index].search('p.mdItem').map{|e| e.inner_html.gsub(/&nbsp;/, '')}
      metadata[label] = value unless value.empty?
    end
    metadata
  end
  
  # Extract a hash of all the metadata tags and values
  def extract_metadata_tags(page)
    r = raw_metadata(page)
    r.each_pair {|key, value| r[key] = value.join(', ')}
    r
  end

  def strip_tags(doc)
    str=doc.to_s
    str.gsub(/<\/?[^>]*>/, "")
  end
  
  def extract_birthday(page)
    #Try to scrape the member's birthday.
    #Here's an example of what we are looking for:
    #<H2>Personal</H2>
    #<P>Born 9.1.42
    # or
    #<H2>Personal</H2><P>
    #<P>Born 4.11.1957

    born = page.parser.to_s.match("Born\\s\\d\\d?\\.\\d\\d?\\.\\d\\d(\\d\\d)?")
    if(born and born.to_s.size > 0)
      born_text = born.to_s[5..-1]
      born_text = born_text.insert(-3, "19") if born_text.match("\\.\\d\\d$") # change 9.1.42 to 9.1.1942
      birthday = Date.strptime(born_text, "%d.%m.%Y")
    else
      birthday = nil
    end
    birthday
  end
  
  def extract_image(page)
    img_tag = page.search('div.box').search("img").first
    if img_tag
      relative_image_url = img_tag.attributes['src']
      #begin
        #puts "About to lookup image #{relative_image_url}..."
        res = @agent.get(relative_image_url)
        Magick::Image.from_blob(res.body)[0]
      #rescue RuntimeError, Magick::ImageMagickError, WWW::Mechanize::ResponseCodeError
      #  return nil
      #end
    end
  end
end
